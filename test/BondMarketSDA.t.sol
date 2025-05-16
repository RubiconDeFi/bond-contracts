pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {WETH, ERC20} from "solmate/tokens/WETH.sol";
import {IBondSDA} from "../src/interfaces/IBondSDA.sol";
import {BondAggregator} from "../src/BondAggregator.sol";
import {BondFixedTermTeller} from "../src/BondFixedTermTeller.sol";
import {IBondTeller} from "../src/interfaces/IBondTeller.sol";
import {BondFixedTermSDA} from "../src/BondFixedTermSDA.sol";
import {RolesAuthority, Authority} from "solmate/auth/authorities/RolesAuthority.sol";

import {console} from "forge-std/console.sol";

/// @dev Bond Market Sequenial Dutch Auctioneer.
contract BondMarketSDA is Test {
    BondAggregator public aggregator;
    BondFixedTermSDA public fixedTermSDA;
    BondFixedTermTeller public tellerFixedTerm;

    RolesAuthority public authority;
    address public guardian;
    address public buyer = vm.addr(0x69228322);

    ERC20 public payoutToken;
    ERC20 public quoteToken;
    uint256 public payoutCapacity;

    uint256 public purchaseAmount;

    uint32 public DEPOSIT_INTERVAL_SEC = 1 hours;
    uint32 public MARKET_DURATION_SEC = 24 hours;
    uint48 public FIXED_EXPIRY_VESTING_TIMESTAMP;

    function setUp() public {
        guardian = msg.sender;
        /// @dev Deploy 'RolesAuthority' contract controlled only by the owner.
        authority = new RolesAuthority(guardian, Authority(address(0)));

        aggregator = new BondAggregator(guardian, authority);
        tellerFixedTerm = new BondFixedTermTeller({
            protocol_: guardian, // address that will receive fees.
            aggregator_: aggregator,
            guardian_: guardian,
            authority_: authority
        });
        // TODO: set protocol fee.
        fixedTermSDA = new BondFixedTermSDA({
            teller_: tellerFixedTerm,
            aggregator_: aggregator,
            guardian_: guardian,
            authority_: authority
        });

        WETH w0 = new WETH();
        WETH w1 = new WETH();

        vm.startPrank(guardian);
        tellerFixedTerm.setProtocolFee(15);
        aggregator.registerAuctioneer(fixedTermSDA);

        w0.deposit{value: 10e18}();
        w1.deposit{value: 10e18}();

        purchaseAmount = 5e17;
        w1.transfer(buyer, purchaseAmount);

        payoutToken = ERC20(address(w0));
        quoteToken = ERC20(address(w1));

        payoutCapacity = payoutToken.balanceOf(msg.sender);
        console.log("payoutCapacity:", payoutCapacity);
        assertGt(payoutCapacity, 0);

        /// @dev Approve payout
        payoutToken.approve(address(tellerFixedTerm), payoutCapacity);
        vm.stopPrank();

        FIXED_EXPIRY_VESTING_TIMESTAMP =
            uint48(block.timestamp) +
            MARKET_DURATION_SEC +
            1;
    }

    function test_launchFixedTermSDA() external {
        (
            uint256 fmtPrice,
            uint256 minFmtPrice,
            int8 scaleAdjustment
        ) = _formatPrice();
        IBondSDA.MarketParams memory marketParams = IBondSDA.MarketParams({
            payoutToken: payoutToken,
            quoteToken: quoteToken,
            callbackAddr: address(0),
            capacityInQuote: false,
            capacity: payoutCapacity,
            formattedInitialPrice: fmtPrice,
            formattedMinimumPrice: minFmtPrice,
            debtBuffer: 0.25 * 1e3, /// @dev Taken from `MarketParams` comment.
            vesting: FIXED_EXPIRY_VESTING_TIMESTAMP,
            start: 0,
            duration: MARKET_DURATION_SEC,
            depositInterval: DEPOSIT_INTERVAL_SEC,
            scaleAdjustment: scaleAdjustment
        });
        vm.startPrank(guardian);
        uint256 id = fixedTermSDA.createMarket(abi.encode(marketParams));
        vm.stopPrank();

        uint256 marketPrice = aggregator.marketPrice(id);
        console.log("market_price:", marketPrice);
        uint256 marketScale = aggregator.marketScale(id);
        console.log("market_scale:", marketScale);

        (address owner, , , , uint48 vesting, uint256 maxPayout) = fixedTermSDA
            .getMarketInfoForPurchase(id);
        console.log("max_payout:", maxPayout);
        console.log("vesting   :", vesting);

        console.log("debt:", fixedTermSDA.currentDebt(id));

        /// @dev Purchase a bond
        vm.startPrank(buyer);
        quoteToken.approve(
            address(tellerFixedTerm),
            quoteToken.balanceOf(buyer)
        );
        (uint256 futurePayout, uint48 expiryTime) = tellerFixedTerm.purchase(
            buyer,
            address(0),
            id,
            purchaseAmount,
            1 // min. amount out
        );
        vm.stopPrank();

        console.log("future_payout:", futurePayout);
        console.log("but when     ?", expiryTime);

        uint256 tokenId = tellerFixedTerm.getTokenId(
            payoutToken,
            uint48(expiryTime)
        );
        console.log("token ID |", tokenId);

        uint256 payoutbalance0 = payoutToken.balanceOf(buyer);
        vm.warp(expiryTime);
        // TODO: redeem a bond for payout.
        vm.startPrank(buyer);
        tellerFixedTerm.redeem(tokenId, futurePayout);
        vm.stopPrank();
        uint256 payoutbalance1 = payoutToken.balanceOf(buyer);

        assertEq(payoutbalance1 - payoutbalance0, futurePayout);
    }

    // https://dev.bondprotocol.finance/smart-contracts/bond-system/auctioneer/fixed-price-auctioneer-fpa#calculating-formatted-price-and-scale-adjustment
    function _formatPrice()
        internal
        view
        returns (
            uint256 _fmtPrice,
            uint256 _minFmtPrice,
            int8 _scaleAdjustement
        )
    {
        /// @dev Payout token data.
        // Фp  = $0.00032
        // фp  = 3.2
        // dфp = -4
        // dp  = 18

        /// @dev Quote token data.
        // Фq  = $1,853
        // фq  = 1.853
        // dфq = 3
        // dq  = 18

        /// @dev Scale Adjustement.
        // s = dp-dq - floor((dфp-dфq)/2)
        //   -> 0    - floor((-4-3)/2)
        //   -> 0    - (-4)
        //   -> 4
        _scaleAdjustement = 4;

        // formatted price = (payoutPriceCoefficient / quotePriceCoefficient)
        //   * 10**(36 + scaleAdjustment + quoteDecimals - payoutDecimals
        //   + payoutPriceDecimals - quotePriceDecimals)
        // (3.2/1.853) * 10**(36 + 4 + 18 - 18 + (-4) - 3)
        _fmtPrice = 1.72692930383 * 10 ** (33);
        /// @dev Adjust, knowing the real price.
        _fmtPrice = 1.72692930383 * 10 ** (40);
        /// @dev Minimum prices to be paid for Quote tokens.
        _minFmtPrice = 1.32282930383 * 10 ** (40);
    }
}
