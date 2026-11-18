// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LottoBots — agent-first lucky-draw ERC-721 mint (BNB Chain)
/// Mechanics (locked with the owner 2026-11-06):
///  - Supply cap 5,000.
///  - First 300 mints are FREE (max 2 free per wallet) and gated to holders
///    of a Binance Agent ID (.ai, SPACE ID registry on BNB Chain): the free
///    phase checks the registry's balanceOf on-chain, so only wallets with
///    an Agent ID can claim a free seat. Paid mints are open to everyone.
///  - Paid mints use a lucky-draw price. Buyer sends MAX_PRICE (0.0001 BNB);
///    the draw decides the real charge and the excess is refunded instantly:
///      1%  -> JACKPOT: charge 0, the NFT is flagged GOLDEN.
///      10% -> 0.00006 BNB (~$0.04)
///      44% -> 0.00009 BNB (~$0.06)
///      45% -> 0.0001  BNB (~$0.07)
///  - Max 10 NFTs per wallet in total (free + paid).
///  - Charged amounts are forwarded to the treasury wallet immediately;
///    nothing accumulates in the contract except in-flight refunds.
contract LottoBots {
    // ---------- ERC-721 basics ----------
    string public name;
    string public symbol;
    string public baseURI;

    uint256 public totalMinted;
    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    // ---------- Sale mechanics ----------
    uint256 public constant MAX_SUPPLY = 5000;
    uint256 public constant FREE_SUPPLY = 300;
    uint256 public constant FREE_PER_WALLET = 2;
    uint256 public constant MAX_PER_WALLET = 10;

    uint256 public constant PRICE_LOW  = 0.00006 ether; // ~$0.04
    uint256 public constant PRICE_MID  = 0.00009 ether; // ~$0.06
    uint256 public constant PRICE_HIGH = 0.0001  ether; // ~$0.07

    // USDT (BEP-20, 18 decimals on BSC) — same tiers priced in USDT exactly.
    // Address is a constructor argument (BSC USDT: 0x55d398326f99059fF775485246999027B3197955).
    IERC20 public immutable USDT;
    uint256 public constant PRICE_LOW_USDT  = 0.04 ether; // $0.04
    uint256 public constant PRICE_MID_USDT  = 0.06 ether; // $0.06
    uint256 public constant PRICE_HIGH_USDT = 0.07 ether; // $0.07

    // Binance Agent ID registry (SPACE ID, BNB Chain mainnet:
    // 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F). Passed as a constructor
    // argument so tests can substitute a mock; immutable after deploy.
    IAgentID public immutable AGENT_ID;

    address public owner;
    address public treasury;

    mapping(address => uint256) public mintedBy;      // total per wallet
    mapping(address => uint256) public freeMintedBy;  // free mints per wallet
    mapping(uint256 => bool) public isGolden;         // jackpot tokens
    uint256 public goldenCount;

    event Minted(address indexed buyer, uint256 indexed tokenId, uint256 paidWei, bool golden);
    event FreeMinted(address indexed buyer, uint256 indexed tokenId);

    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor(string memory _name, string memory _symbol, string memory _baseURI, address _treasury, address _usdt, address _agentId) {
        name = _name;
        symbol = _symbol;
        baseURI = _baseURI;
        owner = msg.sender;
        treasury = _treasury;
        USDT = IERC20(_usdt);
        AGENT_ID = IAgentID(_agentId);
    }

    /// @notice True if the wallet holds a Binance Agent ID (.ai).
    function hasAgentID(address who) public view returns (bool) {
        return AGENT_ID.balanceOf(who) > 0;
    }

    // ---------- Minting ----------
    function mintFree() external returns (uint256 tokenId) {
        require(hasAgentID(msg.sender), "Agent ID required for free mint");
        require(totalMinted < FREE_SUPPLY, "free phase over");
        require(freeMintedBy[msg.sender] < FREE_PER_WALLET, "free limit per wallet");
        require(mintedBy[msg.sender] < MAX_PER_WALLET, "wallet cap");
        tokenId = ++totalMinted;
        freeMintedBy[msg.sender]++;
        mintedBy[msg.sender]++;
        _mint(msg.sender, tokenId);
        emit FreeMinted(msg.sender, tokenId);
    }

    /// @dev tier: 0 = golden jackpot (1%), 1 = low (10%), 2 = mid (44%), 3 = high (45%)
    function _tier(uint256 roll) internal pure returns (uint8) {
        if (roll < 1) return 0;
        if (roll < 11) return 1;
        if (roll < 55) return 2;
        return 3;
    }

    function mintPaid() external payable returns (uint256 tokenId, uint256 charged, bool golden) {
        require(totalMinted >= FREE_SUPPLY, "still in free phase");
        require(totalMinted < MAX_SUPPLY, "sold out");
        require(mintedBy[msg.sender] < MAX_PER_WALLET, "wallet cap");
        require(msg.value >= PRICE_HIGH, "send max price");

        uint8 tier = _tier(_roll(msg.sender));
        golden = tier == 0;
        charged = tier == 0 ? 0 : tier == 1 ? PRICE_LOW : tier == 2 ? PRICE_MID : PRICE_HIGH;

        tokenId = ++totalMinted;
        mintedBy[msg.sender]++;
        if (golden) { isGolden[tokenId] = true; goldenCount++; }
        _mint(msg.sender, tokenId);

        if (charged > 0) {
            (bool ok, ) = payable(treasury).call{value: charged}("");
            require(ok, "treasury transfer failed");
        }
        uint256 refund = msg.value - charged;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "refund failed");
        }
        emit Minted(msg.sender, tokenId, charged, golden);
    }

    event MintedUSDT(address indexed buyer, uint256 indexed tokenId, uint256 paidUsdt, bool golden);

    /// @notice Same lucky draw, paid in USDT. Buyer must first approve this
    /// contract for at least PRICE_HIGH_USDT (0.07 USDT). The draw runs first
    /// and the contract then pulls ONLY the drawn amount (0 / 0.04 / 0.06 /
    /// 0.07 USDT) straight to the treasury — no refund step is needed.
    function mintPaidUSDT() external returns (uint256 tokenId, uint256 charged, bool golden) {
        require(totalMinted >= FREE_SUPPLY, "still in free phase");
        require(totalMinted < MAX_SUPPLY, "sold out");
        require(mintedBy[msg.sender] < MAX_PER_WALLET, "wallet cap");
        require(USDT.allowance(msg.sender, address(this)) >= PRICE_HIGH_USDT, "approve USDT first");
        require(USDT.balanceOf(msg.sender) >= PRICE_HIGH_USDT, "insufficient USDT");

        uint8 tier = _tier(_roll(msg.sender));
        golden = tier == 0;
        charged = tier == 0 ? 0 : tier == 1 ? PRICE_LOW_USDT : tier == 2 ? PRICE_MID_USDT : PRICE_HIGH_USDT;

        tokenId = ++totalMinted;
        mintedBy[msg.sender]++;
        if (golden) { isGolden[tokenId] = true; goldenCount++; }
        _mint(msg.sender, tokenId);

        if (charged > 0) {
            require(USDT.transferFrom(msg.sender, treasury, charged), "USDT charge failed");
        }
        emit MintedUSDT(msg.sender, tokenId, charged, golden);
        emit Minted(msg.sender, tokenId, charged, golden);
    }

    /// @notice View helper for agents/UIs: what phase are we in and what does a wallet have left?
    function saleInfo(address who) external view returns (
        uint256 minted, uint256 supplyCap, bool freePhase,
        uint256 freeLeftGlobal, uint256 freeLeftWallet, uint256 walletMinted, uint256 walletCapLeft,
        bool agentIdHolder
    ) {
        minted = totalMinted;
        supplyCap = MAX_SUPPLY;
        freePhase = totalMinted < FREE_SUPPLY;
        freeLeftGlobal = freePhase ? FREE_SUPPLY - totalMinted : 0;
        freeLeftWallet = freeMintedBy[who] >= FREE_PER_WALLET ? 0 : FREE_PER_WALLET - freeMintedBy[who];
        walletMinted = mintedBy[who];
        walletCapLeft = mintedBy[who] >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - mintedBy[who];
        agentIdHolder = hasAgentID(who);
    }

    function _roll(address buyer) internal view returns (uint256) {
        bytes32 h = keccak256(abi.encodePacked(blockhash(block.number - 1), buyer, totalMinted, block.timestamp));
        return uint256(h) % 100;
    }

    // ---------- ERC-721 implementation ----------
    function _mint(address to, uint256 tokenId) internal {
        require(to != address(0), "mint to zero");
        _balances[to]++;
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function balanceOf(address who) external view returns (uint256) {
        require(who != address(0), "zero address");
        return _balances[who];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "nonexistent token");
        return o;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_owners[tokenId] != address(0), "nonexistent token");
        return string(abi.encodePacked(baseURI, _toString(tokenId), ".json"));
    }

    function approve(address to, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_owners[tokenId] != address(0), "nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address who, address operator) external view returns (bool) {
        return _operatorApprovals[who][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "not authorized");
        require(ownerOf(tokenId) == from, "from is not owner");
        require(to != address(0), "transfer to zero");
        _tokenApprovals[tokenId] = address(0);
        emit Approval(from, address(0), tokenId);
        _balances[from]--;
        _balances[to]++;
        _owners[tokenId] = to;
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
        require(!_isContract(to) || _checkOnERC721Received(from, to, tokenId, ""), "not ERC721 receiver");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) external {
        transferFrom(from, to, tokenId);
        require(!_isContract(to) || _checkOnERC721Received(from, to, tokenId, data), "not ERC721 receiver");
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x80ac58cd || interfaceId == 0x01ffc9a7;
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address o = ownerOf(tokenId);
        return spender == o || _tokenApprovals[tokenId] == spender || _operatorApprovals[o][spender];
    }

    function _isContract(address a) internal view returns (bool) {
        return a.code.length > 0;
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) internal returns (bool) {
        try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
            return retval == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 digits;
        uint256 t = v;
        while (t != 0) { digits++; t /= 10; }
        bytes memory b = new bytes(digits);
        while (v != 0) { b[--digits] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    // ---------- Admin ----------
    function setBaseURI(string memory _baseURI) external onlyOwner { baseURI = _baseURI; }
    function setTreasury(address _treasury) external onlyOwner { treasury = _treasury; }

    receive() external payable {}
}

interface IAgentID {
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}
