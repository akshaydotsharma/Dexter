import Foundation

/// The order the Tasks list's Completed section reads in (#534).
///
/// Out here rather than inside `TasksView` for the reason `TaskBucketWindow` is:
/// ordering is a rule, and a rule living as a private function inside a SwiftUI
/// view is a rule no test can reach.
///
/// ## Latest first
///
/// A finished task is read newest-first. The task you just ticked is the one you
/// look for, either to be sure it landed or to put it back. Every open bucket
/// still reads soonest-first, because an open task is a claim about what happens
/// next; a completed one is only a record of what happened.
///
/// Before this the section had no sort at all. It inherited the store's
/// `createdAt` ascending order, so the row you had just ticked appeared wherever
/// that task happened to have been created, often pages down.
///
/// ## Why `updatedAt` stands in for a completion time
///
/// There is no `completedAt` column, and adding one to `LocalTodo` would leave
/// every task already completed with a null to guess at. `TodoService.toggleCompleted`
/// writes `updatedAt`, so for any task not touched since, `updatedAt` IS the
/// completion time.
///
/// The accepted cost: editing a completed task moves it up the section. That is
/// mild, and arguably right, since an edit is also a kind of recency.
enum CompletedTaskOrder {

    /// Completed tasks, most recently completed first. `createdAt` breaks a tie
    /// so two tasks written in the same instant cannot swap on a re-render.
    static func latestFirst(_ todos: [Todo]) -> [Todo] {
        todos.sorted { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.createdAt > b.createdAt
        }
    }
}
