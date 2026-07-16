# Windows-Assed Windows App Specification

**Status:** Evergreen reference specification
**Audience:** Product, design, engineering, QA, and release review

## Purpose

This specification defines the qualities of a *Windows-assed* Windows app: an app that is unapologetically designed for Windows, behaves as Windows users expect, and uses the operating system as a working environment rather than treating it as a thin frame around a web or phone interface.

“Windows-assed” is used here in parallel with “Mac-assed”: it means idiomatic and platform-respectful, not old-fashioned, visually generic, or limited to a particular UI framework. The result should feel at home beside File Explorer, the taskbar, the notification area, and the rest of a user’s Windows workflow.

## Product principle

The app should reward Windows fluency. A user who knows standard keyboard shortcuts, File Explorer, the taskbar, context menus, window snapping, and system settings should be able to predict the app’s behavior. The product may have a distinctive identity, but it must not make ordinary Windows work harder, less accessible, or less reliable.

## Requirements

### 1. Native interaction model

- Use standard Windows controls and system behaviors wherever they meet the need. Custom controls must retain equivalent semantics, keyboard behavior, focus behavior, accessibility information, and high-DPI rendering.
- Design for desktop work: mouse and keyboard, precision selection, large displays, resizable layouts, multiple monitors, side-by-side work, and extended sessions are normal use cases.
- Do not transplant a touch-first or browser-first interaction model into a desktop window. Do not substitute hidden gestures or oversized in-content controls for menus, context menus, keyboard shortcuts, selection, and drag and drop.
- Support light and dark modes, system accent colors where appropriate, text scaling, high-contrast themes, reduced motion, and per-monitor DPI changes.

### 2. Commands, menus, and keyboard control

- Make important commands discoverable through conventional menus, command bars, toolbars, context menus, or their established Windows equivalent. A shortcut alone is not sufficient discovery.
- Use familiar commands and shortcuts where their meanings are established: New, Open, Close, Save, Save As, Print, Undo, Redo, Cut, Copy, Paste, Select All, Find, Refresh, and Settings or Options where applicable.
- Never silently repurpose a standard shortcut for an unrelated action.
- Provide keyboard equivalents for frequent actions, logical tab order, visible focus, and reliable access keys or accelerator behavior where appropriate.
- Respect conventional key meanings: Escape cancels or backs out of the current transient interaction; Enter confirms the default action; Tab and Shift-Tab move focus; arrow keys navigate compatible controls; Delete removes the selected item only when that action is clear and safe.
- Keep command labels, enabled states, and contextual-menu contents truthful to the current selection and application state.

### 3. Windows, layout, and task management

- Use each window as an independent workspace. When the domain has independently useful documents, records, projects, or views, users must be able to open and work with more than one at a time.
- Support normal resize, minimize, maximize, restore, close, Alt-Tab, taskbar activation, and window snapping behavior. Do not block system window management with custom chrome unless every equivalent system behavior remains available and accessible.
- Persist useful workspace state, such as window size, position, selected item, open tabs, and pane arrangement, while avoiding restoration of misleading or destructive transient state.
- Respond correctly to monitor changes, disconnected displays, different scaling factors, and narrow-but-usable window sizes.
- Do not force a single-window or modal workflow when the user needs to compare, reference, or edit more than one thing.

### 4. Files, data, and interoperability

- Use standard Windows file pickers, Save As, Open With, Export, Import, Print, and Share mechanisms where applicable. Do not require proprietary pickers for ordinary file access.
- Treat user data as theirs. Prefer recognizable formats, preserve fidelity through export and import, and make storage locations understandable.
- Integrate with File Explorer: support opening associated files, sensible file type names and icons, drag and drop into and out of the app, and copy/paste of compatible file content where relevant.
- Support the clipboard fully. Copy useful standard representations, accept compatible pasted content, and explain unsupported content without discarding unrelated clipboard data.
- Respect user-selected paths, libraries, removable drives, network shares, and permissions. Do not assume a cloud-synced folder or hidden app storage is the only valid location for user work.

### 5. Text, editing, and undo

- Use the system text stack wherever practical. Editable text must support selection, standard editing commands, input methods, spell checking where appropriate, dictation when available, and accessibility.
- Every user-initiated, reversible change must participate in coherent Undo and Redo. Undo should reverse the action the user reasonably believes they just performed, with sensible grouping for continuous edits.
- Never lose typed or edited content because of focus changes, synchronization, background refreshes, view recreation, or an incomplete undo implementation.
- Make destructive actions explicit and, when feasible, reversible. For deletions, make the scope and result clear before committing irreversible loss.

### 6. Accessibility and assistive technologies

- Meet the functional intent of current Windows accessibility guidance: correct accessible names, roles, values, states, logical focus order, visible focus, keyboard operation, and programmatic notifications for meaningful changes.
- Verify core flows with Narrator and other UI Automation clients. A custom control is incomplete until it communicates and operates correctly through assistive technology.
- Do not communicate essential state only through color, animation, sound, hover, or a pointer-only affordance.
- Ensure readable text under larger text settings and high-contrast themes. Maintain sufficient contrast and do not bake essential colors into raster assets or hard-coded palettes.

### 7. Windows shell and system integration

- Integrate purposefully with Windows capabilities that improve the task: taskbar behavior, notifications, jump lists, file associations, context-menu actions, sharing, printing, search, clipboard history, and system settings.
- Use notifications only for timely, actionable information. Make permission, quiet-hours behavior, and in-app notification controls understandable.
- Respect the user’s default browser, default apps, locale, time zone, date and number formats, keyboard layouts, input methods, and power settings.
- Behave predictably offline, when suspended or backgrounded, after sleep or wake, and under constrained power or network conditions. Clearly distinguish local state, pending work, and remote state.

### 8. Performance, reliability, and trust

- Launch promptly and remain responsive during work. Keep typing, selection, scrolling, resizing, and menu interactions fluid; run expensive work away from the UI thread.
- For work that takes time, provide a meaningful status, progress indicator, and safe cancellation behavior where possible. Do not use an indeterminate spinner as a substitute for explaining a long-running operation.
- Recover gracefully from network loss, unavailable accounts, missing drives, malformed external files, interrupted updates, and unexpected shutdown. Errors must state what happened, what data is safe, and the next useful action.
- Default to privacy-preserving behavior. Request permissions in context, explain their purpose, minimize collection and transmission, and do not disguise cloud work as instant local work.
- Update safely: preserve user work, communicate material changes, avoid surprise restarts while the app is in use, and offer recovery when an update fails.

### 9. Visual design

- Use a calm, information-capable desktop layout. Support details, lists, tables, trees, filters, property panes, and multiple columns when they help users manage real work.
- Apply established Windows patterns with intent: navigation pane for app sections, command bar or toolbar for frequent actions, context menu for selection-specific actions, dialog for focused configuration, flyout for lightweight contextual choices, and confirmation dialog for consequential decisions.
- Preserve semantic distinction in controls. Buttons, toggles, links, text fields, selections, and static labels must look and behave according to their roles.
- Avoid novelty that obscures hierarchy or breaks user expectations: fake browser chrome, unexplained icons, hover-only controls, a command palette as the only command surface, nonstandard scrolling, or decoration that conceals information density.

## Implementation guidance

This specification does not mandate a particular framework. WinUI, Windows App SDK, WPF, Win32, .NET MAUI, and a mixed architecture are all acceptable. The implementation choice is successful only when it delivers the behavior required above. Use lower-level Windows APIs or interoperate with established controls when an abstraction cannot provide correct keyboard, accessibility, shell, text, or window behavior; framework purity is not a reason to ship a degraded Windows experience.

## Explicit non-goals

- Pixel-for-pixel imitation of a particular Windows release or legacy application.
- Avoiding all custom design or distinctive branding.
- Adding every possible Windows integration whether or not it serves the product.
- Treating an app as compliant merely because it uses a Windows framework or has Fluent styling.
- Sacrificing a task-specific improvement for convention when the improvement is demonstrably clearer, accessible, reversible, and consistent.

## Release acceptance checklist

A feature or release meets this specification when the team can answer “yes” to each applicable question:

- Can a user discover and invoke every important command through an appropriate conventional command surface or keyboard shortcut?
- Can a keyboard-only user and a Narrator user complete the core flows?
- Do standard editing, selection, clipboard, drag-and-drop, Undo/Redo, printing, and file behaviors work as users expect?
- Does the app handle multiple windows, multiple monitors, resizing, snapping, and unsaved work without surprise or data loss?
- Does it preserve user choice and context across restarts, sleep/wake, failures, and routine background activity?
- Does it use Windows shell and system integrations where they make the task faster, clearer, or more trustworthy?
- Has it been verified with light and dark modes, high contrast, text scaling, keyboard navigation, Narrator, common DPI settings, and realistic window sizes?
- Is every departure from Windows convention intentional, documented, and demonstrably better for the relevant task?

## Review standard

When a design decision is contested, prefer the option that is most predictable to an experienced Windows user, most operable with standard system tools, most accessible, most reversible, and most respectful of the user’s data, attention, and workspace. A Windows-assed app earns its character through those details, not through a framework name or superficial visual styling.
