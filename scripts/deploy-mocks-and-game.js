const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 1) Deploy mocks
  const MockERC1155 = await hre.ethers.getContractFactory("MockERC1155");
  const nft = await MockERC1155.deploy("ipfs://mock/{id}.json");
  await nft.waitForDeployment();

  const ticket = await MockERC1155.deploy("ipfs://ticket/{id}.json");
  await ticket.waitForDeployment();

  const MockMana = await hre.ethers.getContractFactory("MockMana");
  const mana = await MockMana.deploy();
  await mana.waitForDeployment();

  const MockPoints = await hre.ethers.getContractFactory("MockPoints");
  const points = await MockPoints.deploy();
  await points.waitForDeployment();

  const MockReward = await hre.ethers.getContractFactory("MockReward");
  const reward = await MockReward.deploy();
  await reward.waitForDeployment();

  console.log("NFT:", await nft.getAddress());
  console.log("Ticket:", await ticket.getAddress());
  console.log("Mana:", await mana.getAddress());
  console.log("Points:", await points.getAddress());
  console.log("Reward:", await reward.getAddress());

  // 2) Configurar mocks para testar rápido (mint)
  // Elementais tokenIds 1..25: mint 1 do tokenId 1 para deployer
  await (await nft.mint(deployer.address, 1, 1)).wait();

  // Tickets: ids 1,2,3 (eco, business, first) -> mint 1 do id 1
  await (await ticket.mint(deployer.address, 1, 1)).wait();

  // Mana: mint 10
  await (await mana.mintMana(deployer.address, 10)).wait();

  // 3) Deploy jogo
  const ElementalDuel = await hre.ethers.getContractFactory("ElementalDuel");

  const revealWindow = 600;
  const joinTimeout = 900;

  const game = await ElementalDuel.deploy(
    await nft.getAddress(),
    await ticket.getAddress(),
    await mana.getAddress(),
    await points.getAddress(),
    await reward.getAddress(),
    revealWindow,
    joinTimeout
  );

  await game.waitForDeployment();
  console.log("Game:", await game.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});