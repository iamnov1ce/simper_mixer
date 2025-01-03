// SPDX-License-Identifier:MIT
pragma solidity ^0.8.20;

import "./MiMC5Sponge.sol";
import "./ReentrancyGuard.sol";

interface IVerifier {
    /**
     * @notice 验证零知识证明的接口函数。
     * @param a Groth16证明参数a
     * @param b Groth16证明参数b
     * @param c Groth16证明参数c
     * @param input 输入参数数组，包括 merkle root、nullifierHash 和接收者地址信息。
     */
    function verifyProof(
        uint[2] memory a, 
        uint[2][2] memory b, 
        uint[2] memory c, 
        uint[3] memory input
        ) external;
}

/**
 * @title Mixer (混币器)
 * @notice 该合约实现一个简单的混币功能。用户通过 deposit 将资金混入树中，再通过
 *         withdraw 使用零知识证明提取资金，以隐藏资金流转信息。
 */
contract Mixer is ReentrancyGuard {
    // 验证器合约地址（零知识证明验证）
    address public verifier;
    // 哈希器合约地址（用于节点哈希，MiMC Sponge哈希函数）
    Hasher public hasher;
    // 当前叶子可插入的索引（即下一个叶子的位置）
    uint256 public nextLeafIndex = 0;

    // Merkle树的层数（默认10层）
    uint8 public constant TREELEVEL = 10;
    // 存入的固定数量（如0.1 ETH）
    uint256 public constant DENOMINATION = 0.1 ether;

    // 记录已知的root集合，用于快速验证给定root是否为有效的Merkle树根
    mapping(uint256 => bool) public roots;
    // 每一层最后一个插入值的哈希（用于构造新的Merkle路径）
    mapping(uint8 => uint256) public lastLevelHash;
    // 已使用的nullifier哈希集合，防止重复提取
    mapping(uint256 => bool) public nullifierHashes;
    // 已提交的承诺(commitment)，防止重复存入
    mapping(uint256 => bool) public commitments;
    
    /**
     * @dev 每一层在空树时的默认值（默克尔树空节点值）
     *      在构造Merkle树时，需要使用默认的空值填充树。
     */
    uint256[10] public levelDefaults = [
        71118845224645581560661547290474275672625766920188865106505383865222737874651,
        93794874811739472496157221636026241863179161587218080013988564305515442926754,
        12037846115979348549489552365439271141151148382543942305621239868636146311048,
        52601035327612737358627996368976073738236256322867069502286317387117454210999,
        40596940499797568772766507227530247974824107581783987122718151131159709517704,
        20487656350804503044446232127184721662482007067023747321697315816564353884993,
        72373528497014557305041270550489425862533703148964675391484753304053251697699,
        29313826558076078598839608077013531358387025166520089511933459109579676627745,
        32264998650100764574700465004437338115040024743134281814039240920703351577708,
        29098166381951239265671145275979968039815993925022990655287306936254084582180
    ];

    // 事件：存款完成后记录树的根、参与哈希的配对值，以及方向信息
    event Deposit(uint256 root, uint256[10] hashPairings, uint8[10] pairDirection);
    // 事件：提款完成后记录接收地址和nullifierHash（用作防止重复花费的标记）
    event Withdrawal(address to, uint256 nullifierHash);

    // /**
    //  * @param _hasher MiMC哈希器合约地址
    //  * @param _verifier 零知识证明验证器合约地址
    //  */
    constructor(
        address _hasher,
        address _verifier
    ) {
        hasher = Hasher(_hasher);
        verifier = _verifier;
    }

    /**
     * @notice 用户存款函数，将资金混入Merkle树中，并更新Merkle根。
     * @param _commitment 用户对自己资金的承诺（叶子值）
     */
    function deposit(uint256 _commitment) external payable nonReentrant {
        require(msg.value == DENOMINATION, "You can only deposite 1 ether");
        require(!commitments[_commitment], "Commitment existed");
        require(nextLeafIndex < 2 ** TREELEVEL, "Merkle tree is full");

        uint256 newRoot;
        // 用于记录在构造Merkle路径时出现的hash配对值
        uint256[10] memory hashPairings;
        // 用于记录左右子哈希的方向，0表示当前叶子在左，1表示在右
        uint8[10] memory hashDirections;

        uint256 currentIndex = nextLeafIndex;
        uint256 currentHash = _commitment;

        // 临时变量保存左右子节点值
        uint256 left;
        uint256 right;
        uint256[2] memory inputs;
        
        // 从叶子向上构建Merkle路径，直到根节点
        for(uint8 i = 0; i < TREELEVEL; i++){
            if (currentIndex % 2 == 0) {
                // 当当前索引为偶数，currentHash在左侧
                left = currentHash;
                right = levelDefaults[i];
                hashPairings[i] = levelDefaults[i];
                hashDirections[i] = 0;
            } else {
                // 当当前索引为奇数，currentHash在右侧
                left = lastLevelHash[i];
                right = currentHash;
                hashPairings[i] = lastLevelHash[i];
                hashDirections[i] = 1;
            }

            // 更新当前层的哈希值存储
            lastLevelHash[i] = currentHash;

            inputs[0] = left;
            inputs[1] = right;

            // 使用MiMC Sponge哈希函数计算新的父节点哈希
            (uint256 h) = hasher.MiMC5Sponge{ gas: 150000 }(inputs, _commitment);

            currentHash = h;
            currentIndex = currentIndex / 2;
        }

        // 新的Merkle根
        newRoot = currentHash;
        roots[newRoot] = true;
        nextLeafIndex += 1;

        // 标记该承诺已经使用过
        commitments[_commitment] = true;

        emit Deposit(newRoot, hashPairings, hashDirections);
    }

    /*
    withdraw的签名要和Verifier.sol中的verifyProof函数一致
    function verifyProof (
        uint[2] calldata _pA, 
        uint[2][2] calldata _pB, 
        uint[2] calldata _pC, 
        uint[3] calldata _pubSignals
        ) public view returns (bool){}
    */
    function withdraw(
        uint[2] memory a,
        uint[2][2] memory b,
        uint[2] memory c,
        uint[2] memory input    // 最后一项recipient不作为变量输入，而是直接读取msg.sender，以防止盗取proof修改地址
    ) external payable nonReentrant {

        // 从input里获取root和_nullifierHash
        uint256 _root = input[0];
        uint256 _nullifierHash = input[1];
        // 从msg.sender获取recipient
        uint256 _address = uint256(uint160(msg.sender));

        require(!nullifierHashes[_nullifierHash], "used withdraw");
        require(roots[_root], "invalid root");

        // 调用Verifier合约对proof进行验证
        (bool verifyOK, ) = verifier.call(abi.encodeCall(IVerifier.verifyProof, (a, b, c, [_root, _nullifierHash, _address])));

        require(verifyOK, "invalid proof");

        // nullifierHashes标记为已经使用
        nullifierHashes[_nullifierHash] = true;
        address payable target = payable(msg.sender);

        // mixer发送0.1ether给接收者
        (bool ok, ) = target.call{ value: DENOMINATION }("");

        require(ok, "withdraw failed");

        emit Withdrawal(msg.sender, _nullifierHash);
    }
}
