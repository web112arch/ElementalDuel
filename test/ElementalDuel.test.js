const { expect } = require("chai");
const hre = require("hardhat");

describe("ElementalDuel", function () {
  it("deploys and allows startGame for a player with mana", async function () {
    const [owner] = await hre.ethers.getSigners();

    const MockERC1155 = await hre.ethers.getContractFactory("MockERC1155");
    const nft = await MockERC1155.deploy("ipfs://mock/{id}.json");
    const ticket = await MockERC1155.deploy("ipfs://ticket/{id}.json");

    const MockMana = await hre.ethers.getContractFactory("MockMana");
    const mana = await MockMana.deploy();

    const MockPoints = await hre.ethers.getContractFactory("MockPoints");
    const points = await MockPoints.deploy();

    const MockReward = await hre.ethers.getContractFactory("MockReward");
    const reward = await MockReward.deploy();

    const ElementalDuel = await hre.ethers.getContractFactory("ElementalDuel");
    const game = await ElementalDuel.deploy(
      await nft.getAddress(),
      await ticket.getAddress(),
      await mana.getAddress(),
      await points.getAddress(),
      await reward.getAddress(),
      600,
      900
    );

    // Mint mana
    await (await mana.mintMana(owner.address, 1)).wait();

    // commitment dummy (qualquer bytes32 != 0)
    const commitment = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("test"));
    await expect(game.startGame(commitment)).to.not.be.reverted;
  });
});