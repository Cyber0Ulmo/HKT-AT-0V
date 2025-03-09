// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155URIStorage} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title Flight Ticket Management System
 * @dev ERC1155-based flight ticket system with booking, cancellation, and fund management capabilities
 */
contract FlightTicket is ERC1155URIStorage, Ownable {
    /// @dev Using Open Zeppelin Address
    using Address for address;

    /// @dev Events declarations
    event FlightTicket_FlightCreated(
        uint256 indexed _flightId,
        string _airportOrigin,
        string _airportDestination,
        uint48 _departureTime,
        string _aircraftModel,
        uint16 _totalSeats,
        uint96 _price
    );
    event FlightTicket_SeatBooked(address indexed _passenger, uint256 indexed _flightId);
    event FlightTicket_TicketCancelled(address indexed _passenger, uint256 indexed _flightId);
    event FlightTicket_BalanceClaimed(address indexed _passenger, uint256 _amount);
    event FlightTicket_FundsWithdrawn(uint256 indexed _flightId, uint256 _amount);

    /// @dev Error declarations
    error FlightTicket_InvalidIATA(string _airportOrigin, string _airportDestination);
    error FlightTicket_AircraftCannotBeEmpty(string _aircraftModel);
    error FlightTicket_FlightCannotBeLessThanOneWeek(uint256 _departureTime, uint256 _currentTimestamp);
    error FlightTicket_SeatsMustBeGreaterThanZero(uint256 _totalSeats);
    error FlightTicket_FlightDoesNotExist(uint256 _flightId);
    error FlightTicket_NoSeatsAvailable(uint256 _flightId, uint256 _seatsBooked, uint256 _totalSeats);
    error FlightTicket_IncorrectPaymentAmount(uint256 _flightId, uint256 _msgValue, uint256 _ticketPrice);
    error FlightTicket_FlightTicketFinished(uint256 _ticketFinished);
    error FlightTicket_NoTicketFound(address _sender, uint256 _flightId);
    error FlightTicket_PassengerWithoutBalance(address _passenger);
    error FlightTicket_WaitForFlightTime(uint256 _flightId, uint256 _departureTime);
    error FlightTicket_FlightAlreadyDeparted(uint256 _departureTime, uint256 _currentTimestamp);
    error FlightTicket_TooLateToCancel(uint256 _latestCancelTime, uint256 _currentTimestamp);
    error FlightTicket_TooLateToBook(uint256 _latestBookingTime, uint256 _currentTimestamp);
    error FlightTicket_BalanceOverflow(uint256 currentBalance, uint256 addedBalance, uint256 totalBalance);

    /**
     * @dev Struct representing a flight.
     * @param departureTime UNIX timestamp of departure
     * @param totalSeats Maximum seat capacity
     * @param seatsBooked Currently reserved seats
     * @param price Ticket price in wei
     * @param balance Accumulated funds for the flight
     * @param airportOrigin IATA code of departure airport
     * @param airportDestination IATA code of arrival airport
     * @param aircraftModel ICAO aircraft type designation
     */
    struct Flight {
        uint48 departureTime;
        uint16 totalSeats;
        uint16 seatsBooked;
        uint96 price;
        uint96 balance;
        string airportOrigin;
        string airportDestination;
        string aircraftModel;
    }

    /// @dev Mapping from flight ID to Flight struct.
    mapping(uint256 => Flight) public s_flights;

    /// @dev Mapping from passenger address to their balance.
    mapping(address => uint256) private s_passengerBalance;

    /// @dev Counter for flight IDs.
    uint256 public s_flightId;

    /**
     * @notice Initializes the contract.
     * @param _initialOwner Address of the initial contract owner
     */
    constructor(address _initialOwner) 
        ERC1155("") 
        Ownable(_initialOwner) 
    { /* Intentionally empty */ }

    /**
     * @notice Creates a new flight (Owner only)
     * @dev Validates flight details and stores the new flight information.
     * @param _airportOrigin 3-letter IATA airport code of the origin.
     * @param _airportDestination 3-letter IATA airport code of the destination.
     * @param _departureTime Future UNIX timestamp (min 7 days from now).
     * @param _aircraftModel Aircraft type designation (e.g., Boeing 737).
     * @param _totalSeats Total available seats (must be greater than 0).
     */
    function addFlight(
        string calldata _airportOrigin,
        string calldata _airportDestination,
        uint48 _departureTime, // Saves gas compared to uint256
        string calldata _aircraftModel,
        uint16 _totalSeats // Saves gas compared to uint256
    ) external onlyOwner {
        if (bytes(_airportOrigin).length != 3 ||
            bytes(_airportDestination).length != 3 ||
            keccak256(bytes(_airportOrigin)) == keccak256(bytes(_airportDestination))) 
            revert FlightTicket_InvalidIATA(_airportOrigin, _airportDestination);
        if (_departureTime < block.timestamp + 7 days) 
            revert FlightTicket_FlightCannotBeLessThanOneWeek(_departureTime, uint48(block.timestamp));
        if (bytes(_aircraftModel).length == 0) 
            revert FlightTicket_AircraftCannotBeEmpty(_aircraftModel);
        if (_totalSeats == 0) 
            revert FlightTicket_SeatsMustBeGreaterThanZero(_totalSeats);

        /// @dev Increments the flight ID counter for the next flight.
        s_flightId = s_flightId + 1;

        /// @dev Generates a new flight ID and sets a default ticket price.
        uint256 flightId = s_flightId;
        uint96 price = 0.001 ether;

        /**
         * @dev Stores the flight information in the contract's storage.
         * The flight data includes departure time, total seats, price, and other details.
         */
        s_flights[flightId] = Flight({
            departureTime: uint48(_departureTime),
            totalSeats: _totalSeats,
            seatsBooked: 0,
            price: price,
            balance: 0,
            airportOrigin: _airportOrigin,
            airportDestination: _airportDestination,
            aircraftModel: _aircraftModel
        });

        /// @dev Emits an event containing all relevant flight details.
        emit FlightTicket_FlightCreated(
            flightId,
            _airportOrigin,
            _airportDestination,
            _departureTime,
            _aircraftModel,
            _totalSeats,
            price
        );

        _updateFlightURI(flightId);
    }

    /**
     * @notice Internal function to update flight metadata URI.
     * @param _flightId The ID of the flight.
     */
    function _updateFlightURI(uint256 _flightId) internal {
        string memory baseURI = "<https://ipfs.io/ipfs/bafkreihqotmgl5nz5mtytsfcgs33pw27bfl2wll5u4hilbsp7w7b5jc2pu/>";
        string memory tokenURI = string(abi.encodePacked(baseURI, _uintToString(_flightId), ".json"));
        _setURI(_flightId, tokenURI);
    }

    /**
     * @dev Converts a uint256 to a string.
     * @param _value The integer to convert.
     * @return The string representation.
     */
    function _uintToString(uint256 _value) internal pure returns (string memory) {
        if (_value == 0) return "0";
        uint256 temp = _value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (_value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + _value % 10));
            _value /= 10;
        }
        return string(buffer);
    }

    function getFlight(uint256 _flightId) external view returns(Flight memory flight) {
        return flight = s_flights[_flightId];
    }

    /**
     * @notice Returns the available seats for the specified flight.
     * @dev This function checks if the flight exists and calculates the remaining available seats by subtracting
     * the number of booked seats from the total seats. If the flight ID is invalid, it reverts.
     * @param _flightId The ID of the flight for which to check the available seats.
     * @return availableSeats_ The number of remaining available seats for the specified flight.
     */
    function getSeatStatus(uint256 _flightId) external view returns (uint256 availableSeats_) {
        /// @dev Checks if the flight ID is valid. Reverts if the flight does not exist.
        if (_flightId > s_flightId) revert FlightTicket_FlightDoesNotExist(_flightId);

        /// @dev Returns the number of available seats by subtracting the number of booked seats from total seats.
        return s_flights[_flightId].totalSeats - s_flights[_flightId].seatsBooked;
    }

    /**
     * @notice Books a seat on the specified flight by the caller.
     * @dev Implements the Checks-Effects-Interactions (CEI) pattern to ensure the integrity of the contract state.
     * This function allows users to book a seat on a flight by paying the exact ticket price. It also ensures 
     * that all necessary conditions are met before the booking is finalized, including seat availability, 
     * payment correctness, and balance overflow prevention.
     * @param _flightId The ID of the flight to book the seat for.
     */
    function bookSeat(uint256 _flightId) external payable {
        /// @notice CHECKS
        /// @dev Validates that the flight ID exists. Reverts if the flight does not exist.
        if (_flightId > s_flightId) revert FlightTicket_FlightDoesNotExist(_flightId);

        /**
         * @dev Ensures that the booking is made at least one hour before the flight's departure.
         * Reverts if the booking is attempted too close to the flight's departure time.
         */
        if (block.timestamp >= s_flights[_flightId].departureTime - 1 hours) 
            revert FlightTicket_FlightTicketFinished(s_flights[_flightId].departureTime - 1 hours);
        
        Flight storage flight = s_flights[_flightId];

        /// @dev Ensures that there are available seats for booking. Reverts if all seats are booked.
        if (flight.seatsBooked >= flight.totalSeats) 
            revert FlightTicket_NoSeatsAvailable(_flightId, flight.seatsBooked, flight.totalSeats);

        /**
         * @dev Verifies that the payment made by the caller is exactly equal to the flight's ticket price.
         * Reverts if the payment amount is incorrect.
         */
        if (flight.price != msg.value)
            revert FlightTicket_IncorrectPaymentAmount(_flightId, msg.value, flight.price);

        /// @notice EFFECTS
        /**
         * @dev Increments the number of booked seats and updates the flight's balance.
         * The booking is successfully processed in the contract's state.
         */
        ++flight.seatsBooked;
        flight.balance = uint96(flight.balance + msg.value); // Safe conversion after overflow check

        /// @dev Emits an event indicating that a seat has been successfully booked for the caller.
        emit FlightTicket_SeatBooked(msg.sender, _flightId);

        /// @notice INTERACTIONS
        /**
         * @dev Mints a new ERC1155 token representing the seat booking for the caller.
         * The caller receives a token for the booked seat.
         * ERC1155 internal interaction
         */
        _mint(msg.sender, _flightId, 1, "");
    }

    /**
     * @notice Books a seat on a specified flight using the caller's passenger balance.
     * @dev Implements the Checks-Effects-Interactions (CEI) pattern to ensure the integrity of the contract state.
     * This function allows users to book a seat by paying with their existing passenger balance. 
     * The function verifies the available balance, ensures that the flight exists, and checks seat availability before 
     * finalizing the booking.
     * @param _flightId The ID of the flight to book the seat for.
     */
    function bookSeatUsingPassengerBalance(uint256 _flightId) external {
        /// @notice CHECKS
        /// @dev Validates that the flight ID exists. Reverts if the flight does not exist.
        if (_flightId > s_flightId) revert FlightTicket_FlightDoesNotExist(_flightId);

        /**
         * @dev Ensures that the booking is made at least one hour before the flight's departure.
         * Reverts if the booking is attempted too close to the flight's departure time.
         */
        if (block.timestamp >= s_flights[_flightId].departureTime - 1 hours) 
            revert FlightTicket_FlightTicketFinished(s_flights[_flightId].departureTime - 1 hours);
            
        Flight storage flight = s_flights[_flightId];

        /// @dev Ensures that there are available seats for booking. Reverts if all seats are booked.
        if (flight.seatsBooked >= flight.totalSeats) 
            revert FlightTicket_NoSeatsAvailable(_flightId, flight.seatsBooked, flight.totalSeats);
        
        /**
         * @dev Verifies that the caller's passenger balance is sufficient to cover the flight's ticket price.
         * Reverts if the balance is less than the price.
         */
        if(flight.price > s_passengerBalance[msg.sender])
            revert FlightTicket_IncorrectPaymentAmount(_flightId, s_passengerBalance[msg.sender], flight.price);

        /// @dev Deducts the ticket price from the caller's passenger balance.
        s_passengerBalance[msg.sender] = s_passengerBalance[msg.sender] - flight.price;        

        /// @notice EFFECTS
        /**
         * @dev Increments the number of booked seats and updates the flight's balance.
         * The booking is successfully processed in the contract's state.
         */
        ++flight.seatsBooked;
        flight.balance = flight.balance + flight.price;

        /// @dev Emits an event indicating that a seat has been successfully booked for the caller.
        emit FlightTicket_SeatBooked(msg.sender, _flightId);

        /// @notice INTERACTIONS
        /**
         * @dev Mints a new ERC1155 token representing the seat booking for the caller.
         * The caller receives a token for the booked seat.
         * ERC1155 internal interaction
         */
        _mint(msg.sender, _flightId, 1, "");
    }

    function addPassengerBalance() external payable {
        if (msg.value == 0 )  revert FlightTicket_PassengerWithoutBalance(msg.sender);
        if (msg.value > type(uint96).max) revert FlightTicket_BalanceOverflow(0, 0, msg.value);
        if (s_passengerBalance[msg.sender] + msg.value > type(uint96).max) 
            revert FlightTicket_BalanceOverflow(0, s_passengerBalance[msg.sender], msg.value);
        s_passengerBalance[msg.sender] = s_passengerBalance[msg.sender] + msg.value;
    }
    
    /**
     * @notice Returns the balance of the caller's passenger account.
     * @dev This function checks if the caller has a non-zero balance and returns it. 
     * If the caller's balance is zero, it reverts with an appropriate error.
     * @return balance_ The balance of the caller's passenger account.
     */
    function getPassengerBalance(address _passenger) external view returns(uint256 balance_) {
        ///
        return s_passengerBalance[_passenger];
    }

    /**
     * @notice Cancels a booked ticket for the caller.
     * @dev Implements strict validation and the Checks-Effects-Interactions (CEI) pattern to ensure the ticket can be 
     * canceled. The function ensures the flight has not yet departed, and that the cancellation is requested 
     * at least an hour before departure. It refunds the ticket price to the caller's balance and burns the ticket.
     * @param _flightId The ID of the flight to cancel the ticket for.
     */
    function cancelTicket(uint256 _flightId) external {
        /// @notice CHECKS
        /// @dev Validates that the flight ID exists. Reverts if the flight does not exist.
        if (_flightId > s_flightId) revert FlightTicket_FlightDoesNotExist(_flightId);
        /// @dev Verifies that the caller holds a ticket for the specified flight. Reverts if no ticket is found.
        if (balanceOf(msg.sender, _flightId) == 0) revert FlightTicket_NoTicketFound(msg.sender, _flightId);

        /**
         * @dev Ensures that the cancellation is requested at least one hour before the flight's departure.
         * Reverts if the cancellation is requested too close to the departure time.
         */
        if (block.timestamp >= s_flights[_flightId].departureTime - 1 hours) {
            revert FlightTicket_FlightTicketFinished(s_flights[_flightId].departureTime - 1 hours);
        }
        
        Flight storage flight = s_flights[_flightId];

        /// @dev Verifies that the flight has not yet departed. Reverts if the flight has already departed.
        if (block.timestamp >= flight.departureTime) {
            revert FlightTicket_FlightAlreadyDeparted(flight.departureTime, block.timestamp);
        }

        /// @dev Ensures that the cancellation is requested before it is too late (less than an hour before departure).
        if (block.timestamp >= flight.departureTime - 1 hours) {
            revert FlightTicket_TooLateToCancel(flight.departureTime, block.timestamp);
        }

        /// @notice EFFECTS
        /// @dev Updates the flight's seat bookings and balance. Refunds the ticket price to the caller's balance.
        --flight.seatsBooked;
        flight.balance = flight.balance - flight.price;
        s_passengerBalance[msg.sender] = s_passengerBalance[msg.sender] + flight.price;

        /// @dev Emits an event indicating that the ticket has been successfully canceled.
        emit FlightTicket_TicketCancelled(msg.sender, _flightId);

        /**
         * @dev Burns the ticket from the caller's account, representing the cancellation of the seat booking.
         * ERC1155 internal interaction
         */ 
        _burn(msg.sender, _flightId, 1);
    }

    /**
     * @notice Withdraws the caller's accumulated passenger balance.
     * @dev Implements the pull payment pattern. The caller can withdraw their balance as ether.
     * This function ensures that only a non-zero balance can be withdrawn and that the transfer is successful.
     */
    function claimPassengerBalance() external {
        /// @notice CHECKS

        uint256 amount = s_passengerBalance[msg.sender];
        /// @dev Verifies that the caller's balance is greater than zero before proceeding with the claim.
        if (amount == 0) revert FlightTicket_PassengerWithoutBalance(msg.sender);

        /// @notice EFFECTS
        /// @dev Resets the caller's balance to zero and emits an event with the claimed amount.
        s_passengerBalance[msg.sender] = 0;
        emit FlightTicket_BalanceClaimed(msg.sender, amount);

        /// @notice INTERACTIONS
        /**
         * @dev Transfers the accumulated balance to the caller as ether.
         * Uses the `call` method to transfer funds and ensures the transfer was successful.
         */
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }
    
    /**
     * @notice Returns the accumulated balance for the specified flight.
     * @dev This function is available only to the contract owner. It allows the owner to check the total 
     * balance accumulated from ticket bookings for a specific flight.
     * @param _flightId The ID of the flight to check the balance for.
     * @return balance_ The current accumulated balance for the flight.
     */
    function getFlightBalance(uint256 _flightId) external view onlyOwner returns (uint256 balance_) {
        /// @dev Verifies that the specified flight exists. Reverts if the flight does not exist.
        if (_flightId > s_flightId) revert FlightTicket_FlightDoesNotExist(_flightId);
        return s_flights[_flightId].balance;
    }

    /**
     * @notice Withdraws the accumulated funds from the specified flight after its departure.
     * @dev Implements the Checks-Effects-Interactions (CEI) pattern to ensure correct fund withdrawal 
     * after the flight has departed. The contract owner can only withdraw the funds once the flight has departed.
     * @param _flightId The ID of the flight to withdraw funds from.
     */
    function withdrawFlightFunds(uint256 _flightId) external onlyOwner {
        /// @notice CHECKS
        /// @dev Validates that the specified flight exists. Reverts if the flight does not exist.
        if (_flightId > s_flightId) revert FlightTicket_FlightDoesNotExist(_flightId);
        
        Flight storage flight = s_flights[_flightId];
        
        /**
         * @dev Ensures that the flight has already departed before the funds can be withdrawn.
         * Reverts if the withdrawal is attempted before the flight's departure time.
         */
        if (block.timestamp < flight.departureTime) {
            revert FlightTicket_WaitForFlightTime(_flightId, flight.departureTime);
        }

        /// @notice EFFECTS
        /// @dev Stores the accumulated balance, resets the flight's balance, and emits an event.
        uint256 amount = flight.balance;
        flight.balance = 0;
        emit FlightTicket_FundsWithdrawn(_flightId, amount);

        /// @notice INTERACTIONS
        /**
         * @dev Transfers the accumulated funds to the owner of the contract. 
         * Ensures the transfer is successful. Consider using Address.sendValue for security.
         */
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }
}