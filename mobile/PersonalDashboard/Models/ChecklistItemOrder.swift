import Foundation

/// Where an item lands in a list when it is ticked or un-ticked (#267, #534).
///
/// A pure function on the array, out here rather than inside `ListsViewModel`,
/// because this is a rule and rules get asserted. The view model still owns the
/// animation and the save; it just asks this what the new array looks like.
///
/// ## The two blocks
///
/// A list is an ACTIVE block on top and a COMPLETED block below it. Nothing
/// interleaves: an item's tick decides which block it is in, and every other
/// operation (adding, dragging) re-asserts the split.
///
/// ## Which end of the completed block a tick lands on
///
/// The top of it, directly under the last active item (#534). Items carry no
/// timestamp, so the stored order of the completed block IS the order things
/// were completed in, and inserting at the top is what makes that order read
/// latest-first. Before this, a tick appended to the very bottom, so the item
/// you just ticked ended up furthest from the one you were working on and the
/// top of the block held whatever you finished first, days ago.
///
/// Un-ticking is unchanged: the item returns to the BOTTOM of the active block,
/// which is where a thing you have just decided is not done belongs — next to
/// the items still to do, not back in the middle of them.
enum ChecklistItemOrder {

    /// The array after the item at `index` has had its tick flipped.
    ///
    /// Returns the items unchanged when `index` is out of bounds, so a stale
    /// index from a row that has just gone away cannot crash a toggle.
    static func afterToggle(_ items: [ChecklistItem], at index: Int) -> [ChecklistItem] {
        guard items.indices.contains(index) else { return items }
        var items = items
        var item = items.remove(at: index)
        item.checked.toggle()
        items.insert(item, at: boundary(items))
        return items
    }

    /// Where a newly added item goes: the end of the active block, so it reads
    /// as the last thing to do rather than landing under the completed ones.
    static func afterAdding(_ item: ChecklistItem, to items: [ChecklistItem]) -> [ChecklistItem] {
        var items = items
        items.insert(item, at: boundary(items))
        return items
    }

    /// Re-assert the split after a drag, keeping the relative order inside each
    /// block (`filter` is stable). The user can reorder the active items freely;
    /// what they cannot do is leave a completed item stranded above an open one.
    static func afterReorder(_ items: [ChecklistItem]) -> [ChecklistItem] {
        items.filter { !$0.checked } + items.filter(\.checked)
    }

    /// The seam between the two blocks: the index of the first completed item,
    /// or the end of the array when nothing is completed.
    ///
    /// Both a tick and an un-tick insert HERE, which is why one call site covers
    /// both: a ticked item at the seam is the newest completed one (top of the
    /// completed block), and an un-ticked item at the seam is the last active one
    /// (bottom of the active block).
    static func boundary(_ items: [ChecklistItem]) -> Int {
        items.firstIndex(where: \.checked) ?? items.count
    }
}
