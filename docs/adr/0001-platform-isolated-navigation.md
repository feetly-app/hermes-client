# ADR 0001: Platform-Isolated Navigation Architecture

## Status
Accepted

## Context
The app runs on iPhone, iPad and Mac. SwiftUI offers `NavigationStack` (push-pop, for compact screens) and `NavigationSplitView` (columns, for wide screens).

A single `NavigationSplitView` driven by list selections caused double pushes and unexpected pops on iPhone. Navigation destinations that built their own transcript also showed empty chats: the destination was rebuilt whenever the browser changed, with a new transcript that was never loaded. Leaving a project screen did not close the project, so a new conversation could land in the wrong project.

## Decision
1. **Compact width (iPhone)**: a single `NavigationStack` with a typed path of `SidebarItem`s: the list, then a project screen, then a chat.
2. **Regular width (iPad, Mac)**: a two-column `NavigationSplitView`. The sidebar path holds the open project at most; the detail column shows the open conversation. On iPad the sidebar is a `NavigationStack` that pushes the project screen. On macOS a `List` pushed in a sidebar stack is never drawn, so the sidebar swaps the conversation list for the project screen, with a back row at its top (⌘[).
3. **One source of truth**: `ConversationBrowser` (open project, open transcript). A path change opens or closes things in the browser; a browser change (new conversation, new or deleted project, fork) rebuilds the paths. The chat always shows the browser's transcript, never one built by a view.

## Consequences
- iPhone navigation stays a plain stack, independent of the split view.
- Creating a conversation, a project, or deleting one moves the navigation in every layout without extra code in the views.
- Switching size class on iPad (multitasking) rebuilds the active layout from the browser.
