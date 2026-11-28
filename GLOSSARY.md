# Glossary

This glossary defines the canonical terminology for the Hermes Client domain model.

## Navigation Concepts

### Two-Column Split View
The layout on macOS and iPadOS (regular horizontal size class):
1. **Sidebar**: the Projects and the Recents. Opening a project shows its screen (repositories and conversations) inside the sidebar: pushed on iPhone and iPad, swapped in with a back row on macOS.
2. **Detail**: the open conversation's message thread and composer.

### Sidebar Folder
A group in the sidebar: the Recents or a Project.
- **Recents**: the conversations that belong to no project.
- **Project**: a sidecar-stored folder that groups related Git repositories and conversations.

### Single-Column Navigation Stack
The push-pop layout used on iPhone (compact size class): the list, then a project screen, then a chat.

### Navigation Path
The list of `SidebarItem`s a layout shows (a project, then a conversation). The browser's open project and open conversation are the source of truth: a path change opens or closes them, and a browser change rebuilds the paths.
