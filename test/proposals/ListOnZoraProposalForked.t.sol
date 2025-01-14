// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8;

import { ListOnZoraProposal } from "contracts/proposals/ListOnZoraProposal.sol";
import { SetupPartyHelper } from "../utils/SetupPartyHelper.sol";
import { DummyERC721 } from "../DummyERC721.sol";
import { LibSafeCast } from "../../contracts/utils/LibSafeCast.sol";
import { PartyGovernance } from "../../contracts/party/PartyGovernance.sol";
import { ProposalExecutionEngine } from "../../contracts/proposals/ProposalExecutionEngine.sol";
import { IReserveAuctionCoreEth } from "../../contracts/vendor/markets/IReserveAuctionCoreEth.sol";

using LibSafeCast for uint256;

contract ListOnZoraProposalForkedTest is SetupPartyHelper {
    constructor() SetupPartyHelper(true) {}

    DummyERC721 nftToken = new DummyERC721();
    uint256 nftTokenId;
    IReserveAuctionCoreEth private ZORA;

    event ZoraAuctionCreated(
        address token,
        uint256 tokenId,
        uint256 startingPrice,
        uint40 duration,
        uint40 timeoutTime
    );
    event ZoraAuctionExpired(address token, uint256 tokenid, uint256 expiry);
    event ZoraAuctionSold(address token, uint256 tokenid);

    // Zora events
    event AuctionCreated(
        address indexed tokenContract,
        uint256 indexed tokenId,
        IReserveAuctionCoreEth.Auction auction
    );
    event AuctionBid(
        address indexed tokenContract,
        uint256 indexed tokenId,
        bool firstBid,
        bool extended,
        IReserveAuctionCoreEth.Auction auction
    );
    event AuctionCanceled(
        address indexed tokenContract,
        uint256 indexed tokenId,
        IReserveAuctionCoreEth.Auction auction
    );
    event AuctionEnded(
        address indexed tokenContract,
        uint256 indexed tokenId,
        IReserveAuctionCoreEth.Auction auction
    );

    function setUp() public override onlyForked {
        super.setUp();
        nftTokenId = nftToken.mint(address(party));

        bytes4 functionSelector = bytes4(keccak256("ZORA()"));
        bytes memory data = abi.encodePacked(functionSelector);

        (, bytes memory res) = address(party).staticcall(data);
        ZORA = IReserveAuctionCoreEth(abi.decode(res, (address)));
    }

    function testForked_canCreateListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        uint256 proposalId = proposeAndPassProposal(proposal);
        _expectEmit3();
        emit AuctionCreated(
            proposalData.token,
            proposalData.tokenId,
            IReserveAuctionCoreEth.Auction({
                seller: address(party),
                reservePrice: uint96(proposalData.listPrice),
                sellerFundsRecipient: address(party),
                highestBid: 0,
                highestBidder: address(0),
                duration: uint32(proposalData.duration),
                startTime: uint32(block.timestamp),
                firstBidTime: 0
            })
        );
        _expectEmit3();
        emit ZoraAuctionCreated(
            proposalData.token,
            proposalData.tokenId,
            proposalData.listPrice,
            proposalData.duration,
            uint40(block.timestamp + proposalData.timeout)
        );
        executeProposal(proposalId, proposal);
    }

    function testForked_canBidOnListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        proposePassAndExecuteProposal(proposal);
        _bidOnListing(proposalData.token, proposalData.tokenId, proposalData.listPrice);
    }

    function testForked_canCancelExpiredListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        (uint256 proposalId, bytes memory progressData) = proposePassAndExecuteProposal(proposal);
        uint32 auctionStartTime = uint32(block.timestamp);
        skip(proposalData.timeout);
        _expectEmit3();
        emit AuctionCanceled(
            proposalData.token,
            proposalData.tokenId,
            IReserveAuctionCoreEth.Auction({
                seller: address(party),
                reservePrice: uint96(proposalData.listPrice),
                sellerFundsRecipient: address(party),
                highestBid: 0,
                highestBidder: address(0),
                duration: uint32(proposalData.duration),
                startTime: auctionStartTime,
                firstBidTime: 0
            })
        );
        _expectEmit3();
        emit ZoraAuctionExpired(proposalData.token, proposalData.tokenId, block.timestamp);
        executeProposal(proposalId, proposal, progressData);
    }

    function testForked_cannotCancelUnexpiredListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        (uint256 proposalId, bytes memory progressData) = proposePassAndExecuteProposal(proposal);
        skip(proposalData.timeout - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListOnZoraProposal.ZoraListingNotExpired.selector,
                proposalData.token,
                proposalData.tokenId,
                block.timestamp + 1
            )
        );
        executeProposal(proposalId, proposal, progressData);
    }

    function testForked_cannotSettleOngoingListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        (uint256 proposalId, bytes memory progressData) = proposePassAndExecuteProposal(proposal);
        _bidOnListing(proposalData.token, proposalData.tokenId, proposalData.listPrice);
        vm.expectRevert(
            abi.encodeWithSelector(
                ListOnZoraProposal.ZoraListingLive.selector,
                proposalData.token,
                proposalData.tokenId,
                block.timestamp + proposalData.duration
            )
        );
        executeProposal(proposalId, proposal, progressData);
    }

    function testForked_canSettleSuccessfulListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        (uint256 proposalId, bytes memory progressData) = proposePassAndExecuteProposal(proposal);
        uint32 auctionStartTime = uint32(block.timestamp);
        _bidOnListing(john, proposalData.token, proposalData.tokenId, proposalData.listPrice);
        skip(proposalData.duration);
        _expectEmit3();
        emit AuctionEnded(
            proposalData.token,
            proposalData.tokenId,
            IReserveAuctionCoreEth.Auction({
                seller: address(party),
                reservePrice: uint96(proposalData.listPrice),
                sellerFundsRecipient: address(party),
                highestBid: uint96(proposalData.listPrice),
                highestBidder: john,
                duration: uint32(proposalData.duration),
                startTime: auctionStartTime,
                firstBidTime: auctionStartTime
            })
        );
        _expectEmit3();
        emit ZoraAuctionSold(proposalData.token, proposalData.tokenId);
        assertTrue(executeProposal(proposalId, proposal, progressData).length == 0);
        assertEq(address(party).balance, proposalData.listPrice);
    }

    function testForked_canSettleSuccessfulEndedListing() external onlyForked {
        (
            PartyGovernance.Proposal memory proposal,
            ListOnZoraProposal.ZoraProposalData memory proposalData
        ) = _buildZoraProposal();
        (uint256 proposalId, bytes memory progressData) = proposePassAndExecuteProposal(proposal);
        uint32 auctionStartTime = uint32(block.timestamp);
        _bidOnListing(john, proposalData.token, proposalData.tokenId, proposalData.listPrice);
        skip(proposalData.duration);
        _expectEmit3();
        emit AuctionEnded(
            proposalData.token,
            proposalData.tokenId,
            IReserveAuctionCoreEth.Auction({
                seller: address(party),
                reservePrice: uint96(proposalData.listPrice),
                sellerFundsRecipient: address(party),
                highestBid: uint96(proposalData.listPrice),
                highestBidder: john,
                duration: uint32(proposalData.duration),
                startTime: auctionStartTime,
                firstBidTime: auctionStartTime
            })
        );
        ZORA.settleAuction(proposalData.token, proposalData.tokenId);
        _expectEmit3();
        emit ZoraAuctionSold(proposalData.token, proposalData.tokenId);
        assertTrue(executeProposal(proposalId, proposal, progressData).length == 0);
        assertEq(address(party).balance, proposalData.listPrice);
    }

    /// MARK: Helpers
    function _bidOnListing(address tokenContract, uint256 tokenId, uint256 bid) private {
        _bidOnListing(_randomAddress(), tokenContract, tokenId, bid);
    }

    function _bidOnListing(
        address bidder,
        address tokenContract,
        uint256 tokenId,
        uint256 bid
    ) private {
        IReserveAuctionCoreEth.Auction memory auction = ZORA.auctionForNFT(tokenContract, tokenId);
        uint256 timeBuffer = 15 minutes;
        vm.deal(bidder, bid);
        vm.prank(bidder);

        // cache needed values
        uint32 firstBidTime = auction.firstBidTime;
        auction.highestBidder = bidder;
        auction.highestBid = bid.safeCastUint256ToUint96();
        auction.firstBidTime = uint32(block.timestamp);

        _expectEmit3();
        emit AuctionBid(
            tokenContract,
            tokenId,
            firstBidTime == 0,
            auction.firstBidTime + auction.duration < block.timestamp + timeBuffer,
            auction
        );
        ZORA.createBid{ value: bid }(tokenContract, tokenId);
    }

    function _buildZoraProposal()
        private
        view
        returns (PartyGovernance.Proposal memory, ListOnZoraProposal.ZoraProposalData memory)
    {
        ListOnZoraProposal.ZoraProposalData memory data = ListOnZoraProposal.ZoraProposalData({
            listPrice: _randomUint256() % 1e18,
            timeout: uint40(_randomRange(1 hours, 1 days)),
            duration: uint40(_randomRange(1 hours, 1 days)),
            token: address(nftToken),
            tokenId: nftTokenId
        });

        PartyGovernance.Proposal memory proposal = PartyGovernance.Proposal({
            maxExecutableTime: type(uint40).max,
            cancelDelay: 0,
            proposalData: abi.encodeWithSelector(
                bytes4(uint32(ProposalExecutionEngine.ProposalType.ListOnZora)),
                data
            )
        });

        return (proposal, data);
    }
}

contract BadBidder {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        revert("nope");
    }
}
