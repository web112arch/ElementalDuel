// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @notice Contrato simples para "hub" de jogos + roleta (só gas) + envio de prêmios pelo owner.
/// @dev Não usa OpenZeppelin. Não é upgradeável. Random NÃO é seguro para apostas com dinheiro.

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

contract GameHubRoulette {
    // =========================
    // Ownable (simples)
    // =========================
    address public owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Owner=0");
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Owner=0");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // =========================
    // Events
    // =========================
    event GameAction(
        address indexed player,
        string gameId,
        string action,
        uint256 value,
        uint256 timestamp
    );

    event GameActionWithRandom(
        address indexed player,
        string gameId,
        string action,
        uint256 value,
        uint256[] randomNumbers,
        uint256 timestamp
    );

    event RouletteSpin(
        address indexed player,
        string gameId,
        uint256 result,
        uint256 maxInt,
        uint256 timestamp
    );

    event PrizeSent(
        address indexed player,
        string gameId,
        address prizeToken, // address(0)=nativo
        uint256 amount,
        uint256 timestamp
    );

    event NFTPrizeSent(
        address indexed player,
        string gameId,
        address nft,
        uint256 tokenId,
        uint256 amount,
        uint256 timestamp
    );

    // =========================
    // Logging actions (qualquer um)
    // =========================
    function recordAction(
        string calldata gameId,
        string calldata action,
        uint256 value
    ) external {
        emit GameAction(msg.sender, gameId, action, value, block.timestamp);
    }

    /// @notice Gera N números pseudo-randômicos 0..maxInt e registra no evento (só pra diversão/log).
    function recordActionWithRandom(
        string calldata gameId,
        string calldata action,
        uint256 value,
        uint256 randomNums,
        uint256 maxInt
    ) external {
        require(randomNums > 0, "randomNums=0");
        require(maxInt > 0, "maxInt=0");

        uint256[] memory randomNumbers = new uint256[](randomNums);

        for (uint256 i = 0; i < randomNums; i++) {
            randomNumbers[i] = _weakRandom(maxInt, i);
        }

        emit GameActionWithRandom(
            msg.sender,
            gameId,
            action,
            value,
            randomNumbers,
            block.timestamp
        );
    }

    // =========================
    // Roulette (só gas)
    // =========================
    /// @notice Roleta simples que retorna 0..maxInt e emite evento.
    function spinRoulette(
        string calldata gameId,
        uint256 maxInt
    ) external returns (uint256 result) {
        require(maxInt > 0, "maxInt=0");

        result = _weakRandom(maxInt, 0);

        emit RouletteSpin(msg.sender, gameId, result, maxInt, block.timestamp);
        emit GameAction(msg.sender, gameId, "ROULETTE_SPIN", result, block.timestamp);

        return result;
    }

    // =========================
    // Prêmios (somente owner)
    // =========================

    /// @notice Envia prêmio em coin nativa (token=0) ou ERC20 (token != 0) a partir do saldo do contrato.
    function sendPrize(
        address player,
        address token,
        uint256 amount,
        string calldata gameId
    ) external onlyOwner {
        require(player != address(0), "player=0");

        if (token == address(0)) {
            (bool ok, ) = payable(player).call{value: amount}("");
            require(ok, "Native transfer failed");
        } else {
            _safeERC20Transfer(token, player, amount);
        }

        emit PrizeSent(player, gameId, token, amount, block.timestamp);
    }

    function sendERC721Prize(
        address player,
        address nft,
        uint256 tokenId,
        string calldata gameId
    ) external onlyOwner {
        require(player != address(0), "player=0");
        IERC721(nft).safeTransferFrom(address(this), player, tokenId);
        emit NFTPrizeSent(player, gameId, nft, tokenId, 1, block.timestamp);
    }

    function sendERC1155Prize(
        address player,
        address nft,
        uint256 tokenId,
        uint256 amount,
        string calldata gameId
    ) external onlyOwner {
        require(player != address(0), "player=0");
        IERC1155(nft).safeTransferFrom(address(this), player, tokenId, amount, "");
        emit NFTPrizeSent(player, gameId, nft, tokenId, amount, block.timestamp);
    }

    // Receber coin nativa (ETH na Base/Ethereum)
    receive() external payable {}

    // =========================
    // Internals
    // =========================

    /// @dev Random fraco: serve só pra diversão/log. NÃO use para valor real.
    function _weakRandom(uint256 maxInt, uint256 salt) internal view returns (uint256) {
        // prevrandao existe no PoS (Ethereum/Base etc). Em outras redes pode variar.
        return uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    msg.sender,
                    block.timestamp,
                    block.number,
                    salt
                )
            )
        ) % (maxInt + 1);
    }

    /// @dev “safe transfer” sem OZ: aceita tokens ERC20 que retornam bool e também os que não retornam nada.
    function _safeERC20Transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        require(ok, "ERC20 transfer call failed");

        if (data.length > 0) {
            // Alguns ERC20 retornam bool
            require(abi.decode(data, (bool)), "ERC20 transfer returned false");
        }
    }
}
