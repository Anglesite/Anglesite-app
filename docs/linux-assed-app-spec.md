# Linux-Assed App Specification

**Status:** Evergreen reference specification
**Audience:** Product, design, engineering, QA, packaging, and release review
**Primary desktop target:** Ubuntu Desktop (GNOME)
**Compatibility target:** Other modern freedesktop.org-compatible Linux desktops where practical

## Purpose

This specification defines the qualities of a *Linux-assed* app: software that belongs to a user’s Linux desktop and system, rather than merely running on Linux. It respects the user’s choice of desktop environment, display server, package manager, file layout, theme, accessibility tools, and control over their own machine.

Linux is not one visual platform. This document therefore establishes Ubuntu Desktop’s GNOME environment as the design baseline, then requires interoperable behavior across the common Linux desktop standards. A Linux-assed app should feel deliberate on Ubuntu without assuming that every Linux user has the same shell, compositor, distribution, or installation method.

For Ubuntu’s default desktop, follow the current [GNOME Human Interface Guidelines](https://developer.gnome.org/hig/), especially its [keyboard guidance](https://teams.pages.gitlab.gnome.org/Websites/developer.gnome.org-hig/reference/keyboard.html). For cross-desktop behavior, follow relevant freedesktop.org standards such as the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/) and [Desktop Entry Specification](https://specifications.freedesktop.org/desktop-entry/latest-single/).

## Product principle

The app should respect Linux as an environment the user owns and can inspect, configure, script, package, and replace component by component. It should integrate with the running desktop without assuming control of it. On Ubuntu, that means a comfortable GNOME experience—clear header-bar or menu patterns, adaptive layout, restrained notifications, and system-consistent settings—not a Windows or macOS imitation in a Linux window.

## Requirements

### 1. Ubuntu-first, Linux-aware interaction

- On Ubuntu Desktop, use GNOME patterns and controls where they meet the need. Design for the current GNOME session, its overview, workspaces, header bars, dialogs, settings, and accessibility tools.
- Do not require a traditional menu bar merely because another platform does. On GNOME, use a header bar, primary menu, context menu, shortcut window, and keyboard shortcuts according to the task. Important actions must remain discoverable and keyboard-accessible.
- Use familiar GNOME terminology and behavior: **Settings** for application configuration, **About** for app identity and version information, **Quit** for ending the application, and standard keyboard shortcuts for standard tasks.
- Be adaptive rather than touch-first. The interface must work well at ordinary desktop sizes, when tiled, and in narrow windows; it must also retain efficient mouse, keyboard, and precision-selection behavior.
- Do not assume that Ubuntu’s GNOME session is the only session in which the app will run. On KDE Plasma, Xfce, Cinnamon, COSMIC, and other compatible desktops, remain usable, accessible, and integrated through shared standards even if the visual language is not identical.

### 2. Commands, keyboard operation, and focus

- Every core action must be reachable with the keyboard as well as the pointer. Use the standard GNOME shortcuts whenever the application supports the corresponding function; common examples include `Ctrl+Q` for Quit, `Ctrl+W` for Close, `Ctrl+S` for Save, `Ctrl+O` for Open, `Ctrl+Z`/`Ctrl+Shift+Z` for Undo/Redo, `Ctrl+F` for Find, and `Ctrl+?` for keyboard shortcuts or help.
- Do not silently repurpose well-established shortcuts for unrelated actions.
- Provide a visible, logical focus order; make focus apparent; and ensure Escape, Enter, Tab, arrow keys, Space, and Delete follow the expected behavior of the active control and dialog.
- Use contextual menus for selection-specific commands and make equivalent commands available through a keyboard or another discoverable path.
- Do not make a command palette, hover-only affordance, touch gesture, or undocumented terminal command the only way to invoke an important feature.

### 3. Windows, dialogs, workspaces, and Wayland

- Treat the window manager and compositor as the authority for window placement, stacking, workspaces, shortcuts, and decoration policy. Do not fight tiling, snapping, Alt-Tab, workspace switching, or the system window menu.
- On Ubuntu GNOME, use a normal application window and appropriate header-bar behavior. A client-side header bar is welcome when it preserves system actions, accessible window controls, and clear title/drag regions.
- Prefer a single well-organized primary window for a single task, as GNOME convention suggests. Support multiple windows when the user genuinely benefits from comparing or independently working with documents, projects, or records.
- Use modal dialogs and sheets only for focused, bounded decisions. Do not stack dialogs, make a settings window modal, or force users through a serial wizard for ordinary work.
- Design and test Wayland-first. Do not depend on global screen coordinates, unrestricted window enumeration, synthetic input, arbitrary global shortcuts, or X11-only clipboard/window behavior. Provide a functional X11 fallback where the toolkit supports it, but do not make X11 a requirement.
- Preserve useful state—open work, selection, panel state, and window geometry where valid—across restart and session recovery. Never restore a misleading transient dialog or lose unsaved work.

### 4. Files, data, and interoperability

- Use the system file chooser or the relevant portal for opening, saving, importing, exporting, and selecting folders. In a sandboxed application, use the [XDG Desktop Portal file chooser](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.FileChooser.html) rather than trying to bypass confinement.
- Treat user data as user-owned. Use documented, interoperable formats where possible; preserve data fidelity through export and import; and make it clear where the app stores local files.
- Support drag and drop, selection, and the clipboard using standard MIME types and useful common representations. Never rely solely on a proprietary in-app interchange format when a standard one is practical.
- Integrate with the desktop through a correct `.desktop` entry, application icon, MIME type declarations, file associations, and desktop actions where relevant. Opening a supported file from the file manager must produce the expected app and document state.
- Respect user-selected paths, mounted volumes, network locations, symlinks, and permissions. Do not assume that a home directory is local, that a path is writable, or that a cloud folder is available.
- Use `xdg-open`, MIME associations, or the toolkit’s equivalent to open external resources with the user’s preferred app. Do not hard-code a browser, file manager, terminal emulator, or mail client.

### 5. Data locations, configuration, and inspectability

- Follow the XDG Base Directory Specification. Keep configuration, data, state, cache, and runtime files separate; honor `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME`, and `XDG_RUNTIME_DIR` rather than scattering dotfiles or creating an opaque directory tree in the home folder.
- Do not write outside the app’s permitted locations without an explicit user action or an installation mechanism designed for that scope. Never require `sudo` for normal launch, update, configuration, or user-data access.
- Make settings and stored data understandable and recoverable. When practical, use durable, inspectable formats; document their location and provide export/reset paths. Do not overwrite hand-edited configuration without warning.
- Keep logs useful, bounded, privacy-conscious, and easy for a user to locate or export. Do not discard diagnostic detail that is needed to explain a failed operation.
- If the app offers a command-line interface, it must behave like a good Unix citizen: support `--help`, return meaningful exit statuses, send machine-readable or pipeline output to standard output, errors to standard error, and avoid TTY-only assumptions. A GUI app does not need a CLI merely to satisfy this specification.

### 6. Packaging, updates, and system ownership

- Ship through an installation path appropriate to the intended Ubuntu audience: an Ubuntu-supported package channel, a well-integrated Snap, a Flatpak, a distribution package, or another clearly documented mechanism. Do not make a self-extracting archive in the user’s Downloads folder the only supported experience.
- Treat each published package format as a real product surface. A Snap or Flatpak must work correctly under its confinement and portals; a distribution package must follow filesystem, dependency, and lifecycle conventions. Do not tell users to weaken sandboxing or change system-wide permissions to compensate for packaging defects.
- Integrate updates with the chosen package mechanism. Do not run a hidden, privileged self-updater alongside the system package manager; do not restart over active work without consent.
- Make the app’s name, icon, version, update channel, permissions, and data behavior clear in the app and package metadata. Use a stable reverse-DNS application ID where the platform expects one.
- Avoid needless bundled daemons, background agents, root services, or autostart entries. If a background component is essential, explain it, make it controllable, honor power/network constraints, and remove it cleanly with the app.

### 7. Accessibility, localization, and theming

- Meet the functional intent of current GNOME accessibility guidance: correct accessible names, roles, states, values, relationships, focus order, visible focus, and full keyboard operation.
- Verify core flows with Orca and the Linux accessibility stack used by the selected toolkit. A custom control is incomplete until it works through assistive technology.
- Support text scaling, high-contrast preferences, reduced motion, keyboard navigation, and sufficient contrast. Do not communicate essential state solely with color, sound, animation, hover, or a pointer-only action.
- Use translatable strings, support right-to-left layouts, honor locale formatting, and do not concatenate fragments that translators must reorder.
- On Ubuntu, work with the GNOME/Yaru environment rather than hard-coding a theme, font, dark-mode value, icon treatment, or window decoration. Across desktops, use toolkit theming and portal/system preferences where available; do not promise pixel-identical appearance at the cost of usability.

### 8. System integration, privacy, and reliability

- Use desktop portals and standard services for capabilities that cross security or desktop boundaries: file selection, opening URIs, notifications, screenshots, screen sharing, background access, and other permissioned features. Request only the access the feature needs, in context, and explain why.
- Use notifications sparingly and as actionable status—not as marketing. Respect Do Not Disturb, notification permissions, and the user’s chosen desktop notification behavior.
- Respect proxy settings, certificate stores, locale, time zone, input methods, default applications, network availability, and power constraints. Do not assume a proprietary account, desktop shell extension, or always-on network connection.
- Remain responsive during work. Move expensive work off the UI thread, show truthful progress for long operations, and provide safe cancellation where possible.
- Handle missing dependencies, inaccessible files, portal denial, disconnected mounts, network loss, interrupted updates, and crash recovery clearly. An error must explain what happened, whether the user’s data is safe, and the next useful action.
- Default to local, privacy-preserving behavior. Do not transmit user data, index the user’s files, start a server, or perform background network work without a clear feature-level reason and user-visible control.

### 9. Visual design

- On Ubuntu, prefer the GNOME visual hierarchy: a concise header bar, intentional navigation, clear primary actions, calm spacing, and content that adapts to the available window size. Use sidebars, view switchers, lists, search, tabs, or property panels only when they clarify the task.
- Favor legible, practical information density over a sparse mobile imitation. Linux desktop users often work with files, logs, tables, code, and parallel tasks; give them enough context to work confidently.
- Preserve semantic distinction in controls. A button, link, toggle, text field, list selection, and static label must each look and behave according to their purpose.
- Avoid fake browser chrome, unexplained icon-only controls, platform-incongruent traffic-light window controls, Windows-style ribbon imitation, and decoration that conceals hierarchy or reduces contrast.
- Do not equate “Linux” with a single nostalgic visual style. The goal is a modern, dependable Ubuntu GNOME app that also behaves respectfully elsewhere.

## Implementation guidance

This specification does not mandate a programming language, toolkit, or display protocol. GTK/libadwaita is the natural choice for an Ubuntu GNOME-first product; Qt/KDE, Electron, Flutter, SDL, native Wayland, and other stacks can also meet this standard. The chosen technology is successful only if it delivers the behavior above.

Use the toolkit’s native integration APIs, freedesktop.org specifications, and XDG Desktop Portals when they provide correct desktop behavior. A custom abstraction, bundled runtime, or cross-platform UI layer is not an excuse to lose keyboard access, theming, portals, file integration, assistive-technology support, or user control.

## Explicit non-goals

- Pretending that every Linux desktop environment has the same visual conventions.
- Pixel-for-pixel imitation of a particular Ubuntu or GNOME release.
- Requiring every app to have a command-line interface, root integration, a system service, or every available desktop portal.
- Equating a specific package format, toolkit, display server, or programming language with quality.
- Avoiding all custom design or distinctive branding.
- Sacrificing a task-specific improvement for convention when the improvement is demonstrably clearer, accessible, reversible, and respectful of the user’s control of their system.

## Release acceptance checklist

A feature or release meets this specification when the team can answer “yes” to each applicable question:

- Does the app feel conventional and easy to navigate in a current Ubuntu GNOME session, without importing another platform’s interaction model?
- Can a keyboard-only user and an Orca user complete the core flows?
- Do standard text editing, clipboard, drag and drop, Undo/Redo, opening, saving, import/export, and MIME behaviors work as users expect?
- Does the app behave correctly under Wayland and adapt to window resizing, workspaces, scaling, light/dark mode, and common GNOME settings?
- Does the app follow XDG locations, avoid unnecessary privileges, preserve user data, and expose useful logs and recovery paths?
- Does the selected Snap, Flatpak, distribution package, or other installation path work correctly without weakening its sandbox or circumventing the desktop’s permission model?
- Are `.desktop` metadata, icons, file associations, external links, notifications, and portal-backed features correct on Ubuntu and reasonable on other supported desktops?
- Has the app been tested with a realistic Ubuntu GNOME session, keyboard navigation, Orca, text scaling, high contrast, offline/network-loss behavior, and the actual shipped package format?
- Is every departure from Ubuntu GNOME or shared Linux convention intentional, documented, and demonstrably better for the relevant task?

## Review standard

When a design decision is contested, prefer the option that is most predictable on Ubuntu GNOME, most interoperable with the Linux desktop standards, most accessible, most reversible, and most respectful of the user’s data and system ownership. A Linux-assed app earns its character through integration without overreach: it works with the desktop the user has, gives the user control, and remains useful when the surrounding system differs from the developer’s machine.
