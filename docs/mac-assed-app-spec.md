# Mac-Assed Mac App Specification

**Status:** Evergreen reference specification
**Audience:** Product, design, engineering, QA, and release review

## Purpose

This specification defines the qualities of a *Mac-assed* Mac app: an app that is unapologetically designed for macOS, behaves as Mac users expect, and takes advantage of the platform instead of presenting a web or phone interface inside a desktop window.

The term was popularized by Daring Fireball in reference to apps that are platform-specific, convention-respecting, and accessible rather than aggressively custom. See [“Mac-Assed Mac Apps”](https://daringfireball.net/linked/2020/03/20/mac-assed-mac-apps). This is a product-quality standard, not a requirement to imitate old software or avoid modern design.

## Product principle

The app should feel like it belongs on the user’s Mac. A capable Mac user should be able to predict how it works from established macOS conventions, menus, keyboard shortcuts, and system integrations. The app may have a distinctive visual identity, but never at the expense of clarity, accessibility, or ordinary platform behavior.

## Requirements

### 1. Native interaction model

- Use standard macOS controls and system behaviors wherever they meet the need. Custom controls must preserve the expected semantics, keyboard operation, accessibility behavior, focus behavior, and appearance adaptation of their system counterparts.
- Make desktop use first-class: pointer, keyboard, trackpad, large windows, resizable layouts, multiple simultaneous tasks, and long-lived work are normal—not edge cases.
- Do not transplant a touch-first or browser-first interaction model onto macOS. In particular, do not replace discoverable menus, contextual menus, selection, drag and drop, or keyboard commands with hidden gestures or oversized in-content controls.
- Support the system appearance, accent color, contrast settings, text-size settings where applicable, and reduced-motion preferences without making the interface harder to read or operate.

### 2. Menus, commands, and keyboard control

- Provide a complete menu-bar command structure using standard macOS menu placement and wording. Every significant command must be discoverable from a menu, even when it also appears in a toolbar or contextual menu.
- Use familiar commands and shortcuts where their meanings are established: New, Open, Close, Save, Save As, Print, Undo, Redo, Cut, Copy, Paste, Select All, Find, and Preferences/Settings where applicable.
- Never silently repurpose a standard shortcut for an unrelated operation.
- Make menu titles, enabled states, and validation reflect the current selection and app state.
- Provide keyboard equivalents for frequent actions. Ensure every control and task can be completed without a mouse when the underlying task permits it.
- Treat Escape, Return, Tab, arrow keys, Space, Delete, and modifier keys according to their conventional macOS roles.

### 3. Windows, documents, and state

- Use windows as independent workspaces. When the domain has independently useful documents, records, projects, or views, users must be able to open and work with more than one at a time.
- Preserve each window’s size, position, sidebar state, selection, and other useful context when practical. Restoration must never resurrect destructive or misleading transient state.
- Use the standard window title bar, toolbar, fullscreen behavior, tabs, and document proxy icon where applicable. A custom title bar is justified only when it retains equivalent system behavior and accessibility.
- Respect the close button: closing a window closes that window, not unexpectedly the entire app or unrelated work.
- Prompt before discarding unsaved user changes; do not prompt merely because the app has temporary, recoverable state.

### 4. Files, data, and interoperability

- Use the standard Open, Save, Export, Import, Print, Quick Look, and share mechanisms when relevant. Do not force users through proprietary pickers for ordinary file operations.
- Treat user data as theirs. Use recognizable file formats or clearly documented export paths whenever possible; preserve data fidelity through export and import.
- Support Finder conventions, including drag and drop into and out of the app, file promises where useful, and opening supported documents through Finder or Open With.
- Support the clipboard fully: copy selections in useful standard representations, accept compatible pasted content, and provide truthful feedback for unsupported content.
- Use security-scoped access and sandboxing correctly without making the user repeatedly reauthorize the same normal workflow.

### 5. Text, editing, and undo

- Use the system text system for editable text whenever possible. Text must support selection, standard editing commands, spelling and grammar services where appropriate, input methods, dictation, and accessibility.
- Every user-initiated, reversible change must participate in coherent Undo and Redo. Undo should reverse the action the user believes they just performed, with sensible grouping for continuous edits.
- Never lose typed or edited content because of focus changes, background refreshes, synchronization, view recreation, or an incomplete undo implementation.
- Make destructive actions explicit, reversible where feasible, and proportionate to their consequences.

### 6. Accessibility and assistive technologies

- Meet the functional intent of the current macOS accessibility guidance: meaningful labels, roles, values, hints where needed, logical focus order, visible focus indication, and complete keyboard operation.
- Verify core flows with VoiceOver. A custom control is incomplete until it communicates and operates correctly with assistive technologies.
- Do not communicate essential state only through color, animation, hover, sound, or a pointer-only affordance.
- Ensure text remains readable at larger sizes and under increased contrast; maintain adequate contrast in every supported appearance.

### 7. System integration

- Integrate with macOS services that make sense for the product: Share, Services, Notifications, Spotlight, Quick Look, Finder, printing, drag and drop, App Intents, and the menu bar. Integration must be purposeful, not decorative.
- Use notifications sparingly, only for timely information that warrants interruption, and make their permission and settings understandable.
- Respect the user’s chosen browser, default apps, locale, time zone, calendar conventions, and input sources.
- Behave correctly when offline, when the app is backgrounded, and when system resources are constrained. Clearly distinguish local state, pending work, and remote state.

### 8. Performance, reliability, and trust

- Launch promptly, remain responsive during work, and keep scrolling, typing, resizing, and menu tracking fluid. Move expensive work off the main thread and expose meaningful progress for work that takes time.
- Do not show a blocking progress indicator without a clear operation, status, and cancellation behavior when cancellation is safe.
- Recover gracefully from network loss, unavailable accounts, malformed external files, and interrupted operations. Error messages must explain what happened, what data is safe, and the next useful action.
- Default to privacy-preserving behavior. Request permissions in context, explain their purpose, minimize data collection, and never make a cloud dependency appear local or automatic.

### 9. Visual design

- Prefer information-dense, calm layouts appropriate to a large display. Let users resize panes, inspect detail, and work with lists, tables, and multiple columns when these improve the task.
- Use familiar macOS visual hierarchy: toolbar for common actions, sidebar for navigation, inspector for attributes, sheet for a focused task, popover for lightweight contextual choices, and alert for consequential confirmation.
- Preserve semantic distinctions in controls. A button should look and act like a button; a link should look and act like a link; static text should not masquerade as a control.
- Avoid novelty that makes actions ambiguous: fake browser chrome, unexplained icons, hover-only controls, persistent command palettes in place of menus, and decoration that obscures hierarchy.

## Implementation guidance

This specification does not mandate a particular UI framework. SwiftUI, AppKit, and a mixed architecture are all acceptable. The implementation choice is successful only if it provides the platform behavior required above. Bridge to AppKit or use platform APIs when a framework abstraction cannot yet provide correct Mac behavior; do not accept a degraded interaction merely to keep an implementation framework-pure.

## Explicit non-goals

- Pixel-for-pixel imitation of older versions of macOS.
- Avoiding all custom design or distinctive branding.
- Duplicating every macOS integration regardless of relevance.
- Treating an app as compliant solely because it is written in a native language or uses native controls.
- Sacrificing task-specific improvements for convention when the improvement is demonstrably clearer, accessible, reversible, and consistent.

## Release acceptance checklist

A feature or release meets this specification when the team can answer “yes” to each applicable question:

- Can a user discover and invoke every important command from a conventional menu or keyboard shortcut?
- Can a keyboard-only user and a VoiceOver user complete the core flows?
- Do standard editing, selection, clipboard, drag-and-drop, Undo/Redo, and file behaviors work as users expect?
- Does the app manage windows and unsaved work without surprising loss or forced single-window workflows?
- Does it preserve user choice and context across restarts, failures, and routine background activity?
- Does it use macOS integrations where they make the task faster or more trustworthy?
- Is every departure from macOS convention intentional, documented, and demonstrably better for the relevant task?
- Has the feature been tested in light and dark appearances, with keyboard navigation, VoiceOver, increased contrast, and a realistic range of window sizes?

## Review standard

When a design decision is contested, prefer the option that is most predictable to an experienced Mac user, most operable with standard system tools, most accessible, most reversible, and most respectful of the user’s data and attention. A Mac-assed app earns its character through these details, not through nostalgic styling or a technology label.
