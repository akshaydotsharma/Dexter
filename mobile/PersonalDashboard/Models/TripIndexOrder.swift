import Foundation

/// Which of the three travel states a trip is in (#428).
///
/// A named type rather than two Bools passed down from `TripsView`: the band, the
/// type ramp and the card border all vary by state, and three call sites reading
/// `isPast: true, isActive: false` is how one of them eventually gets it wrong.
///
/// Lives here rather than beside the band it colours because the grouping rule
/// below is what decides it, and that rule is plain date arithmetic with no
/// SwiftUI in it (#534).
enum TripPhase: Equatable {
    case active
    case upcoming
    case past
}

/// Anything the trip index can place on the calendar. `LocalTrip` conforms;
/// tests conform a plain struct, which is the point of the protocol — the rule
/// below is pure date arithmetic and should not need a SwiftData container to
/// assert.
protocol TripDateRange {
    var startDate: Date { get }
    var endDate: Date { get }
}

extension LocalTrip: TripDateRange {}

/// How the trip index groups and orders trips (#534).
///
/// Lifted out of `TripsView` for the same reason `TaskBucketWindow` was lifted
/// out of `TasksView`: ordering is a rule, and a rule living as a private
/// computed property inside a SwiftUI view is a rule no test can reach.
///
/// ## The direction each group reads in
///
/// Active and Upcoming read soonest-first. A trip you have not taken yet is read
/// forwards: the next one to start is the one you are packing for.
///
/// Past reads LATEST FIRST. A finished trip has no "next" left in it, so the only
/// thing its dates still say is how recently it happened, and the trip you just
/// got back from is the one you go looking for. The Wallet's Past stack has always
/// read this way (`WalletEntry.grouped`); this is Trips agreeing with it.
///
/// ## Why the boundaries are day-granular
///
/// Start and end dates are stored normalised to `startOfDay` as UTC anchors
/// (#506), so `today` is anchored the same way before any comparison. A trip
/// spanning today is Active for the whole of today and only drops to Past once
/// its end date is behind us.
enum TripIndexOrder {

    /// The state a trip is in as of `today`, which must already be a day anchor.
    static func phase(of trip: some TripDateRange, today: Date) -> TripPhase {
        if WallClock.startOfStoredDay(trip.endDate) < today { return .past }
        if WallClock.startOfStoredDay(trip.startDate) > today { return .upcoming }
        return .active
    }

    /// The three groups, each in the direction it reads in.
    static func grouped<T: TripDateRange>(
        _ trips: [T],
        today: Date
    ) -> (active: [T], upcoming: [T], past: [T]) {
        var active: [T] = []
        var upcoming: [T] = []
        var past: [T] = []
        for trip in trips {
            switch phase(of: trip, today: today) {
            case .active:   active.append(trip)
            case .upcoming: upcoming.append(trip)
            case .past:     past.append(trip)
            }
        }
        // End date breaks ties so two trips starting the same day order by the
        // one that wraps up first. Past inverts the whole comparison, tiebreak
        // included, so the trip that ended last leads.
        let ascending: (T, T) -> Bool = {
            ($0.startDate, $0.endDate) < ($1.startDate, $1.endDate)
        }
        return (
            active: active.sorted(by: ascending),
            upcoming: upcoming.sorted(by: ascending),
            past: past.sorted { ascending($1, $0) }
        )
    }
}
