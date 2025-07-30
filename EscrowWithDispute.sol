// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Optimized Decentralized Escrow Smart Contract with Dispute Resolution
 * @notice This contract enables gas-efficient, secure peer-to-peer transactions
 * with a robust dispute resolution mechanism, custom timeouts, and dispute staking.
 * It is fully self-contained and does not rely on any external libraries.
 */
contract EscrowWithDispute {
    // ============ Type Declarations ============

    enum State {
        EMPTY, // Default state, transaction does not exist
        AWAITING_DELIVERY,
        DELIVERED,
        DISPUTED,
        CANCELLED,
        RESOLVED
    }

    struct Transaction {
        // --- Slot 0: Parties ---
        address payable buyer;
        address payable seller;
        // --- Slot 1 & 2: Hashes ---
        bytes32 disputeReasonHash;
        bytes32 evidenceHash;
        // --- Slot 3: Amounts (Packed) ---
        uint96 amount;          // 12 bytes
        uint96 disputeStake;    // 12 bytes
        uint64 createdAt;       // 8 bytes
        // --- Slot 4: Timestamps & State (Packed) ---
        uint64 deliveredAt;     // 8 bytes
        uint64 disputeResolvedAt; // 8 bytes
        uint64 deliveryTimeout; // 8 bytes
        uint64 disputeWindow;   // 8 bytes
        State state;            // 1 byte
    }

    // ============ State Variables ============

    mapping(uint256 => Transaction) public transactions;
    uint256 public nextTransactionId;

    address public arbitrator;
    address public owner;

    // Default timeouts (in seconds), can be overridden per transaction
    uint64 public constant DEFAULT_DELIVERY_TIMEOUT = 7 days;
    uint64 public constant DEFAULT_DISPUTE_WINDOW = 3 days;
    
    // Fallback timeout for arbitrator inaction
    uint256 public constant ARBITRATOR_TIMEOUT = 14 days;

    // Stake required from the buyer to raise a dispute
    uint256 public disputeStakeAmount;

    // Optional platform fee in basis points (1% = 100)
    uint256 public platformFeeBps;

    // ============ Events ============

    event TransactionCreated(uint256 indexed transactionId, address indexed buyer, address indexed seller, uint256 amount);
    event TransactionCancelled(uint256 indexed transactionId);
    event DeliveryMarked(uint256 indexed transactionId, uint256 timestamp);
    event DisputeRaised(uint256 indexed transactionId, bytes32 reasonHash, string reason);
    event EvidenceSubmitted(uint256 indexed transactionId, address indexed party, bytes32 evidenceHash);
    event DisputeResolved(uint256 indexed transactionId, address winner);
    event FundsReleased(uint256 indexed transactionId, address recipient);
    event ArbitratorUpdated(address oldArbitrator, address newArbitrator);
    event PlatformFeeUpdated(uint256 newFeeBps);
    event DisputeStakeAmountUpdated(uint256 newStakeAmount);

    // Critical fallback events
    event ArbitratorInactionResolved(uint256 indexed transactionId, address indexed fundsRecipient);
    event DisputeStakeSlashed(uint256 indexed transactionId, address indexed beneficiary, uint256 amount);

    // ============ Modifiers ============

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Only arbitrator can call this function");
        _;
    }

    modifier onlyParty(uint256 _transactionId) {
        require(
            msg.sender == transactions[_transactionId].buyer || msg.sender == transactions[_transactionId].seller,
            "Only buyer or seller can call this function"
        );
        _;
    }

    modifier onlyBuyer(uint256 _transactionId) {
        require(msg.sender == transactions[_transactionId].buyer, "Only buyer can call this function");
        _;
    }

    modifier onlySeller(uint256 _transactionId) {
        require(msg.sender == transactions[_transactionId].seller, "Only seller can call this function");
        _;
    }

    modifier inState(uint256 _transactionId, State _state) {
        require(transactions[_transactionId].state == _state, "Invalid transaction state");
        _;
    }

    bool private locked;
    modifier nonReentrant() {
        require(!locked, "Reentrant call detected");
        locked = true;
        _;
        locked = false;
    }

    // ============ Constructor ============

    constructor(address _arbitrator, uint256 _platformFeeBps, uint256 _initialDisputeStake) {
        owner = msg.sender;
        arbitrator = _arbitrator;
        require(_platformFeeBps < 10000, "Fee cannot be 100% or more");
        platformFeeBps = _platformFeeBps;
        disputeStakeAmount = _initialDisputeStake;
    }

    // ============ External Functions: Transaction Lifecycle ============

    function createTransaction(
        address payable _seller,
        uint64 _deliveryTimeout,
        uint64 _disputeWindow
    ) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "Amount must be greater than 0");
        require(_seller != address(0), "Invalid seller address");
        require(_seller != msg.sender, "Buyer cannot be seller");
        require(msg.value < 2**96, "Amount exceeds 96-bit limit");

        uint256 fee = (msg.value * platformFeeBps) / 10000;
        uint256 escrowAmount = msg.value - fee;

        if (fee > 0) {
            (bool success, ) = owner.call{value: fee}("");
            require(success, "Fee transfer failed");
        }

        uint256 transactionId = nextTransactionId;
        unchecked {
            nextTransactionId++;
        }

        transactions[transactionId] = Transaction({
            buyer: payable(msg.sender),
            seller: _seller,
            disputeReasonHash: bytes32(0),
            evidenceHash: bytes32(0),
            amount: uint96(escrowAmount),
            disputeStake: 0,
            createdAt: uint64(block.timestamp),
            deliveredAt: 0,
            disputeResolvedAt: 0,
            deliveryTimeout: _deliveryTimeout > 0 ? _deliveryTimeout : DEFAULT_DELIVERY_TIMEOUT,
            disputeWindow: _disputeWindow > 0 ? _disputeWindow : DEFAULT_DISPUTE_WINDOW,
            state: State.AWAITING_DELIVERY
        });

        emit TransactionCreated(transactionId, msg.sender, _seller, escrowAmount);
        return transactionId;
    }

    function cancelAndRefund(uint256 _transactionId)
        external
        nonReentrant
        onlyBuyer(_transactionId)
        inState(_transactionId, State.AWAITING_DELIVERY)
    {
        Transaction storage tx_ = transactions[_transactionId];
        require(block.timestamp > tx_.createdAt + tx_.deliveryTimeout, "Delivery timeout not reached");
        
        tx_.state = State.CANCELLED;
        
        (bool success, ) = tx_.buyer.call{value: tx_.amount}("");
        require(success, "Refund transfer failed");

        emit TransactionCancelled(_transactionId);
        emit FundsReleased(_transactionId, tx_.buyer);
        delete transactions[_transactionId];
    }
    
    function markDelivered(uint256 _transactionId)
        external
        onlySeller(_transactionId)
        inState(_transactionId, State.AWAITING_DELIVERY)
    {
        Transaction storage tx_ = transactions[_transactionId];
        tx_.state = State.DELIVERED;
        tx_.deliveredAt = uint64(block.timestamp);

        emit DeliveryMarked(_transactionId, block.timestamp);
    }

    function confirmDelivery(uint256 _transactionId)
        external
        nonReentrant
        onlyBuyer(_transactionId)
        inState(_transactionId, State.DELIVERED)
    {
        Transaction storage tx_ = transactions[_transactionId];
        tx_.state = State.RESOLVED;
        
        (bool success, ) = tx_.seller.call{value: tx_.amount}("");
        require(success, "Transfer to seller failed");

        emit FundsReleased(_transactionId, tx_.seller);
        delete transactions[_transactionId];
    }

    function claimPaymentAfterDisputeWindow(uint256 _transactionId)
        external
        nonReentrant
        onlySeller(_transactionId)
        inState(_transactionId, State.DELIVERED)
    {
        Transaction storage tx_ = transactions[_transactionId];
        require(block.timestamp > tx_.deliveredAt + tx_.disputeWindow, "Dispute window not expired");

        tx_.state = State.RESOLVED;
        (bool success, ) = tx_.seller.call{value: tx_.amount}("");
        require(success, "Transfer to seller failed");

        emit FundsReleased(_transactionId, tx_.seller);
        delete transactions[_transactionId];
    }

    // ============ External Functions: Dispute Handling ============

    function raiseDispute(uint256 _transactionId, string calldata _reason)
        external
        payable
        onlyBuyer(_transactionId)
    {
        require(msg.value == disputeStakeAmount, "Incorrect dispute stake amount");
        Transaction storage tx_ = transactions[_transactionId];
        require(tx_.state == State.DELIVERED, "Can only dispute after delivery");
        require(block.timestamp <= tx_.deliveredAt + tx_.disputeWindow, "Dispute window expired");

        tx_.state = State.DISPUTED;
        tx_.disputeStake = uint96(msg.value);
        bytes32 reasonHash = keccak256(bytes(_reason));
        tx_.disputeReasonHash = reasonHash;

        emit DisputeRaised(_transactionId, reasonHash, _reason);
    }

    function submitEvidence(uint256 _transactionId, bytes32 _evidenceHash)
        external
        onlyParty(_transactionId)
        inState(_transactionId, State.DISPUTED)
    {
        transactions[_transactionId].evidenceHash = _evidenceHash;
        emit EvidenceSubmitted(_transactionId, msg.sender, _evidenceHash);
    }

    function resolveDispute(uint256 _transactionId, bool _refundBuyer)
        external
        nonReentrant
        onlyArbitrator
        inState(_transactionId, State.DISPUTED)
    {
        Transaction storage tx_ = transactions[_transactionId];
        tx_.state = State.RESOLVED;
        tx_.disputeResolvedAt = uint64(block.timestamp);

        if (_refundBuyer) {
            uint256 totalAmount = tx_.amount + tx_.disputeStake;
            (bool success, ) = tx_.buyer.call{value: totalAmount}("");
            require(success, "Refund to buyer failed");
            emit DisputeResolved(_transactionId, tx_.buyer);
            emit FundsReleased(_transactionId, tx_.buyer);
        } else {
            (bool successSeller, ) = tx_.seller.call{value: tx_.amount}("");
            require(successSeller, "Transfer to seller failed");
            
            (bool successStake, ) = tx_.seller.call{value: tx_.disputeStake}("");
            require(successStake, "Stake transfer to seller failed");

            emit DisputeResolved(_transactionId, tx_.seller);
            emit FundsReleased(_transactionId, tx_.seller);
            emit DisputeStakeSlashed(_transactionId, tx_.seller, tx_.disputeStake);
        }
        delete transactions[_transactionId];
    }
    
    function resolveDisputeDueToInaction(uint256 _transactionId)
        external
        nonReentrant
        onlyBuyer(_transactionId)
        inState(_transactionId, State.DISPUTED)
    {
        Transaction storage tx_ = transactions[_transactionId];
        require(tx_.disputeResolvedAt == 0, "Dispute already resolved");
        require(block.timestamp > tx_.createdAt + ARBITRATOR_TIMEOUT, "Arbitrator timeout not reached");
        
        tx_.state = State.RESOLVED;
        
        uint256 totalAmount = tx_.amount + tx_.disputeStake;
        (bool success, ) = tx_.buyer.call{value: totalAmount}("");
        require(success, "Inaction refund to buyer failed");

        emit ArbitratorInactionResolved(_transactionId, tx_.buyer);
        emit FundsReleased(_transactionId, tx_.buyer);
        delete transactions[_transactionId];
    }

    // ============ Admin Functions ============

    function updateArbitrator(address _newArbitrator) external onlyOwner {
        require(_newArbitrator != address(0), "Invalid arbitrator address");
        emit ArbitratorUpdated(arbitrator, _newArbitrator);
        arbitrator = _newArbitrator;
    }

    function updatePlatformFee(uint256 _newFeeBps) external onlyOwner {
        require(_newFeeBps < 10000, "Fee cannot be 100% or more");
        platformFeeBps = _newFeeBps;
        emit PlatformFeeUpdated(_newFeeBps);
    }
    
    function updateDisputeStake(uint256 _newStakeAmount) external onlyOwner {
        disputeStakeAmount = _newStakeAmount;
        emit DisputeStakeAmountUpdated(_newStakeAmount);
    }

    // ============ View Functions ============

    function getState(uint256 _transactionId) public view returns (string memory) {
        State state = transactions[_transactionId].state;
        if (state == State.EMPTY) return "EMPTY";
        if (state == State.AWAITING_DELIVERY) return "AWAITING_DELIVERY";
        if (state == State.DELIVERED) return "DELIVERED";
        if (state == State.DISPUTED) return "DISPUTED";
        if (state == State.CANCELLED) return "CANCELLED";
        if (state == State.RESOLVED) return "RESOLVED";
        return "UNKNOWN";
    }

    function getTransaction(uint256 _transactionId)
        external
        view
        returns (Transaction memory)
    {
        return transactions[_transactionId];
    }
}