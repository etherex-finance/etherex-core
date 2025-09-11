// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IXRex} from "contracts/interfaces/IXRex.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAccessHub} from "contracts/interfaces/IAccessHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ISwapRouter} from "contracts/CL/periphery/interfaces/ISwapRouter.sol";
import {IFeeDistributor} from "contracts/interfaces/IFeeDistributor.sol";
import {IRamsesV3Pool} from "contracts/CL/core/interfaces/IRamsesV3Pool.sol";
import {IPairFactory} from "contracts/interfaces/IPairFactory.sol";
import {IRouter} from "contracts/interfaces/IRouter.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 *
 * ███╗   ███╗███████╗██╗   ██╗
 * ████╗ ████║██╔════╝██║   ██║
 * ██╔████╔██║█████╗  ██║   ██║
 * ██║╚██╔╝██║██╔══╝  ╚██╗ ██╔╝
 * ██║ ╚═╝ ██║███████╗ ╚████╔╝ 
 * ╚═╝     ╚═╝╚══════╝  ╚═══╝  
 *
 * ███╗   ███╗ ██████╗ ██████╗ ██╗   ██╗██╗     ███████╗
 * ████╗ ████║██╔═══██╗██╔══██╗██║   ██║██║     ██╔════╝
 * ██╔████╔██║██║   ██║██║  ██║██║   ██║██║     █████╗  
 * ██║╚██╔╝██║██║   ██║██║  ██║██║   ██║██║     ██╔══╝  
 * ██║ ╚═╝ ██║╚██████╔╝██████╔╝╚██████╔╝███████╗███████╗
 * ╚═╝     ╚═╝ ╚═════╝ ╚═════╝  ╚═════╝ ╚══════╝╚══════╝  v0.0.1
 *
 * @title      RamsesMevModule
 * @notice     Permissioned MEV module for transparent protocol revenue generation
 * 
 * @dev        [CORE FUNCTIONALITY]
 *             =====================
 *             Authorization:
 *             - Only AuthorizedExecutors can use this module
 *             - Fees can only be switched to complete a full arbitrage cycle atomically
 *             - Arbitrary fee switching is forbidden
 *             Revenue share:
 *             - Full transparency
 *             - 100% of proceeds distributed directly to voters via vote bribes
 *             - No other withdrawal methods possible
 *   
 */

contract MevModule is Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// constants
    address public constant RAM = 0xEfD81eeC32B9A8222D1842ec3d99c7532C31e348;
    address public constant XRAM = 0xc93B315971A4f260875103F5DA84cB1E30f366Cc;
    address public constant X33 = 0xe4eEB461Ad1e4ef8b8EF71a33694CCD84Af051C4;
    address public constant WETH = 0xe5D7C2a44FfDDf6b295A15c148167daaAf5Cf34f;

    /// storage
    EnumerableSet.AddressSet private _authorizedExecutors;
    IAccessHub public accessHub;
    ISwapRouter public swapRouter;
    IPairFactory public pairFactory;
    IRouter public legacyRouter;
    

    /// types
    struct AuthorizedSwapParams {
        address[] poolAddresses;
        uint24[] originalFees;
        uint24[] targetFees;
        bool[] concentrated;
    }
    struct SwapIntent {
        address tokenIn;
        address tokenOut;
        int24 feeOrTickspace;
        PoolType poolType;
    }

    enum PoolType {
        LEGACY_STABLE,
        LEGACY_VOLATILE,
        V3
    }
    enum PayloadType {
        ROUTER,
        EXECUTOR
    }
    
    /// errors
    error Unauthorized();
    error Unprofitable(uint256 initialBalance, uint256 finalBalance);
    error NotImplemented();
    /// constructors
    constructor() {
        _disableInitializers();
    }

    /// initializers
    function initialize() external initializer {
        _authorizedExecutors.add(0x676F11a28E5F8A3ebF6Ae1187f05C30b0A95a8b0);
        swapRouter = ISwapRouter(0x8BE024b5c546B5d45CbB23163e1a4dca8fA5052A);  
        accessHub = IAccessHub(0x683035188E3670fda1deF2a7Aa5742DEa28Ed5f3);
        IERC20(RAM).approve(address(swapRouter), type(uint256).max);
        pairFactory = IPairFactory(0xC0b920f6f1d6122B8187c031554dc8194F644592);
        legacyRouter = IRouter(0x32dB39c56C171b4c96e974dDeDe8E42498929c54);
    }

    /// modifiers
    modifier onlyAuthorizedExecutor() {
        if (!_authorizedExecutors.contains(msg.sender)) revert Unauthorized();
        _;
    }
    modifier onlyMultisig() {
        if (msg.sender != accessHub.treasury()) revert Unauthorized();
        _;
    }
    
    /*━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *                  AUTHORIZATION            
     *━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━*/
    function addAuthorizedExecutor(address _executor, bool _isActive) external onlyMultisig {        
        if (_isActive) {
            if (!_authorizedExecutors.contains(_executor)) {
                _authorizedExecutors.add(_executor);
            }
        } else {
            if (_authorizedExecutors.contains(_executor)) {
                _authorizedExecutors.remove(_executor);
            }
        }
    }
    function isAuthorizedExecutor(address _executor) external view returns (bool) {
        return _authorizedExecutors.contains(_executor);
    }
    function authorizedExecutorsCount() external view returns (uint256) {
        return _authorizedExecutors.length();
    }
    modifier authorizedSwap(
        AuthorizedSwapParams calldata _authParams
    ) {
        accessHub.setSwapFees(_authParams.poolAddresses, _authParams.targetFees);
        _;
        accessHub.setSwapFees(_authParams.poolAddresses, _authParams.originalFees);
    }

    /*━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     *                     MEV                    
     *━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━*/
    function computeV3Address(address deployer, address token0, address token1, int24 tickSpacing) internal pure returns (address pool) {
        require(token0 < token1, "!TokenOrder");
        bytes32 POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex'ff',
                            deployer,
                            keccak256(abi.encode(token0, token1, tickSpacing)),
                            POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }

    function initApprovals() external {
        IERC20(RAM).approve(address(XRAM), type(uint256).max);
        IERC20(XRAM).approve(X33, type(uint256).max);
    }

    /**
     * @notice Executes AMO arbitrage when x33 redeem floor is surpassed
     * @dev 
     * Methodology:
     *      ┌────────────────────────────────────────────┐
     *      │ 1. Locate target liquidity pool            │
     *      │ 2. Use authorizedSwap for optimal price    │
     *      │ 3. Purchase x33 tokens using RAM        │
     *      │ 4. Redeem x33 tokens for xRAM           │
     *      │ 5. Perform instant exit: xRAM → RAM  │
     *      │ 6. Bribe arbitrage earnings to voters      │
     *      └────────────────────────────────────────────┘
     * 
     * Benefits: 
     *      ┌───────────────────────────────────────────────────────┐
     *      │ ▶ 50% of instant exit → voters as rebase              │
     *      │ ▶ 100% of arbitrage proceeds → voters as bribes       │
     *      │ ▶ all market inefficiencies captured by protocol      │
     *      └───────────────────────────────────────────────────────┘
     * 
     * @dev Only callable by authorized MEV executors
     */
    function amo(
        ISwapRouter.ExactInputSingleParams calldata _swapParams,
        AuthorizedSwapParams calldata _authParams,
        bool _simulate,
        bool _ceiling
    )
        external
        onlyAuthorizedExecutor
        authorizedSwap(_authParams)
    {

        if (_ceiling) {
           /// snapshot ram inventory
           uint256 balanceBefore = IERC20(RAM).balanceOf(address(this));
           /// ram -> xram
           IXRex(XRAM).convertEmissionsToken(_swapParams.amountIn);
           /// xram -> x33
           IERC4626(X33).deposit(_swapParams.amountIn, address(this));
           /// x33 -> ram swap for profit
           swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: _swapParams.tokenIn,
                tokenOut: _swapParams.tokenOut,
                tickSpacing: _swapParams.tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: IERC20(X33).balanceOf(address(this)),
                amountOutMinimum: _swapParams.amountOutMinimum,
                sqrtPriceLimitX96: _swapParams.sqrtPriceLimitX96
            }));
            uint256 balanceAfter = IERC20(RAM).balanceOf(address(this));
            // short circuit if not profitable or simulation
            if (balanceAfter <= balanceBefore || _simulate) {
                revert Unprofitable(balanceBefore, balanceAfter);
            }
        }
        /// floor arbitrage, we buy x33 with RAM and redeem it for more RAM
        else {
            // snapshot ram inventory
            uint256 balanceBefore = IERC20(RAM).balanceOf(address(this));
            // optimal swap
            uint256 amountOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: _swapParams.tokenIn,
                tokenOut: _swapParams.tokenOut,
                tickSpacing: _swapParams.tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _swapParams.amountIn,
                amountOutMinimum: _swapParams.amountOutMinimum,
                sqrtPriceLimitX96: _swapParams.sqrtPriceLimitX96
            }));
            // x33 -> xram
            IERC4626(X33).redeem(amountOut, address(this), address(this));
            // xram -> ram
            IXRex(XRAM).exit(IERC20(XRAM).balanceOf(address(this)));
            // profit check
            uint256 balanceAfter = IERC20(RAM).balanceOf(address(this));
            // short circuit if not profitable or simulation
            if (balanceAfter <= balanceBefore || _simulate) {
                revert Unprofitable(balanceBefore, balanceAfter);
            }
        }
    }


    /**
     * @notice Executes atomic cyclical n-pool backrun arbitrage opportunities
     * @dev 
     * Methodology:
     *      ┌────────────────────────────────────────────────────────────────┐
     *      │ 1. Identifies profitable cyclical arbitrage paths              │
     *      │    (e.g., wS → TokenA → TokenB → TokenC → wS)                  │
     *      │ 2. Uses authorizedSwap for optimal price execution             │
     *      │ 3. Executes complete arbitrage loop atomically                 │
     *      │ 4. Profit is accumulated in this contract as wS until bribed   │
     *      └────────────────────────────────────────────────────────────────┘
     * 
     * Benefits: 
     *      ┌─────────────────────────────────────────────────────────────────┐
     *      │ ▶ 100% of arbitrage profits distributed to voters as bribes     │
     *      │ ▶ Protects protocol from value extraction by external MEV bots  │
     *      │ ▶ Recaptures value that would otherwise leave the ecosystem     │
     *      │ ▶ Implements a fair, protocol-owned MEV model with equitable    │
     *      │   distribution to stakeholders                                  │
     *      └─────────────────────────────────────────────────────────────────┘
     * 
     * 
     * @dev Only callable by authorized MEV executors
     */
    function backrun(
        PayloadType _payloadType,
        SwapIntent[] calldata _swapIntents,
        uint256 _amountIn,
        AuthorizedSwapParams calldata _authParams,
        bool _simulate
    )   
        external
        onlyAuthorizedExecutor
        authorizedSwap(_authParams)
        returns (uint256 _quoteOut)
    {   
        uint256 balanceBefore = IERC20(WETH).balanceOf(address(this));
        uint256 amountIn;
        uint256 amountOut;
        
        // 0 = ROUTER PAYLOAD
        if (_payloadType == PayloadType.ROUTER) {
            for (uint256 i = 0; i < _swapIntents.length; i++) {
                SwapIntent memory swapIntent = _swapIntents[i];
                // first swap
                if (i == 0) {
                    amountIn = _amountIn;
                }

                // legacy intent
                if (swapIntent.poolType == PoolType.LEGACY_STABLE || swapIntent.poolType == PoolType.LEGACY_VOLATILE) {
                    IRouter.route[] memory routes = new IRouter.route[](1);
                    routes[0] = IRouter.route({
                        from: swapIntent.tokenIn,
                        to: swapIntent.tokenOut,
                        stable: swapIntent.poolType == PoolType.LEGACY_STABLE 
                    });
                    uint256[] memory amounts = legacyRouter.swapExactTokensForTokens(
                        amountIn,
                        0,
                        routes,
                        address(this),
                        block.timestamp
                    );
                    amountOut = amounts[amounts.length - 1];
                }

                // univ3 intent
                else {
                    amountOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                        tokenIn: swapIntent.tokenIn,
                        tokenOut: swapIntent.tokenOut,
                        tickSpacing: swapIntent.feeOrTickspace,
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: amountIn,
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    }));
                }

                // amountOut becomes input for next swap intent
                amountIn = amountOut;
            }
            uint256 balanceAfter = IERC20(WETH).balanceOf(address(this));
            // if simulating, always return the raw quote (meant to be statically called)
            if (_simulate) {
                return amountOut;
            }
            // short circuit if not profitable
            if (balanceAfter <= balanceBefore) {
                revert Unprofitable(balanceBefore, balanceAfter);
            }
   
        }
        // 1 = EXECUTOR PAYLOAD
        if (_payloadType == PayloadType.EXECUTOR) {
            revert NotImplemented();
        }
    }

    /// @dev Quote an authorizedSwap (meant to be statically called)
    function singleQuoteAuthorizedSwap(
        SwapIntent calldata _swapIntent,
        uint256 _amountIn,
        AuthorizedSwapParams calldata _authParams,
        bool _transferFromCaller
    )
        external
        onlyAuthorizedExecutor
        authorizedSwap(_authParams)
        returns (uint256 _quoteOut)

    {
        address tokenIn = _swapIntent.tokenIn;
        
        if (_transferFromCaller) {
            IERC20(tokenIn).transferFrom(msg.sender, address(this), _amountIn);
        }

        // legacy intent
        if (_swapIntent.poolType == PoolType.LEGACY_STABLE || _swapIntent.poolType == PoolType.LEGACY_VOLATILE) {
            IRouter.route[] memory routes = new IRouter.route[](1);
            routes[0] = IRouter.route({
                from: _swapIntent.tokenIn,
                to: _swapIntent.tokenOut,
                stable: _swapIntent.poolType == PoolType.LEGACY_STABLE 
            });
            uint256[] memory amounts = legacyRouter.swapExactTokensForTokens(
                _amountIn,
                0,
                routes,
                address(this),
                block.timestamp
            );
            _quoteOut = amounts[amounts.length - 1];
        }

        // univ3 intent
        else {
            _quoteOut = swapRouter.exactInputSingle(ISwapRouter.ExactInputSingleParams({
                tokenIn: _swapIntent.tokenIn,
                tokenOut: _swapIntent.tokenOut,
                tickSpacing: _swapIntent.feeOrTickspace,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: _amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            }));
        }

        return _quoteOut;
    }



    function sanitizeApprovals(address[] calldata _tokens) external onlyAuthorizedExecutor {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (IERC20(_tokens[i]).allowance(address(this), address(legacyRouter)) < type(uint256).max / 2) {
                IERC20(_tokens[i]).approve(address(legacyRouter), type(uint256).max);
            }
            if (IERC20(_tokens[i]).allowance(address(this), address(swapRouter)) < type(uint256).max / 2) {
                IERC20(_tokens[i]).approve(address(swapRouter), type(uint256).max);
            }
        }
    }

    function setLegacyRouter(address _legacyRouter) external onlyMultisig {
        legacyRouter = IRouter(_legacyRouter);
    }

    function setSwapRouter(address _swapRouter) external onlyMultisig {
        swapRouter = ISwapRouter(_swapRouter);
    }
}

