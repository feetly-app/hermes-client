# Glossary

This glossary defines the canonical terminology for the Hermes Client domain model.

## Navigation Concepts

### Three-Column Split View (Split-View à trois colonnes)
The native layout pattern on macOS and iPadOS (regular horizontal size class) consisting of three distinct columns:
1. **Sidebar (Colonne Primaire)**: Lists the top-level navigational directories (Recents folder and Projects).
2. **Content List (Colonne Secondaire)**: Displays the list of conversations and metadata (e.g. Git repositories) inside the selected folder or project.
3. **Detail Chat (Colonne Tertiaire)**: Displays the active conversation's message thread and composer.

### Sidebar Folder (Dossier de Navigation)
A top-level category in the Sidebar representing either the smart folder for Recents or a custom Project.
- **Recents (Récents)**: A smart folder listing all conversations not associated with any project.
- **Project (Projet)**: A sidecar-stored folder that groups related Git repositories and conversations.

### Single-Column Navigation Stack (Pile de Navigation Unique)
The hierarchical push-pop layout pattern used on iPhone (compact size class) where clicking a Project pushes the project details, and clicking a conversation pushes the chat, fully managed by the OS.
