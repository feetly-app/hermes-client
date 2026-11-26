# ADR 0001: Platform-Isolated Navigation Architecture

## Status
Proposed

## Context
The application is a multiplatform SwiftUI app running on iOS (iPhone), iPadOS (iPad), and macOS (Mac).
SwiftUI provides two primary navigation paradigms: `NavigationStack` (hierarchical push-pop, ideal for compact screens) and `NavigationSplitView` (multi-column split layouts, ideal for regular/wide screens).

Initially, we attempted to use a unified `NavigationSplitView` with custom programmatic routing across all platforms. This resulted in significant platform-specific bugs:
- **On iOS**: Complex layout desynchronization between list selections and active stack paths led to double-push bugs, automatic pop issues on back button clicks, and unexpected redirects to blank placeholders.
- **On macOS/iPadOS**: Nested `NavigationStack` instances inside sidebar columns resulted in buggy rendering, lost selection highlights, and infinite rendering loops.

Apple's Human Interface Guidelines (HIG) recommend a simple hierarchical stack for compact screens, and a multi-column split view for wide screens (specifically a three-column split view for communication and document-focused apps like Mail and Notes).

## Decision
We decide to completely isolate the navigation architectures of iOS (iPhone) and macOS/iPadOS at compile time using Swift's `#if os(macOS)` or size class checks:

1. **iPhone (Compact size class)**: Uses a clean, robust, and single-column **Hierarchical Navigation Stack** (`NavigationStack` as the root container) that is completely native and bug-free on compact screens.
2. **Mac & iPad (Regular size class)**: Uses a native **Three-Column Navigation Split View** (`NavigationSplitView`) consisting of:
   - Column 1: Sidebar (Smart Folder "Recents", and custom Projects list).
   - Column 2: Content List (Conversations inside the selected Sidebar Folder, plus repository management for Projects).
   - Column 3: Detail Chat (Active message thread, styled as a native detail pane).

## Consequences
- **Zero Mobile Regressions**: The iOS navigation remains completely untouched and isolated, guaranteeing 100% safety for the mobile app.
- **Premium Desktop Experience**: macOS and iPadOS receive a first-class, highly polished, native three-column layout that behaves exactly like Apple Mail or Notes.
- **Maintainability**: Future developers can easily modify desktop-specific split-view details or mobile-specific stack flows independently, without fearing cross-platform regressions.
