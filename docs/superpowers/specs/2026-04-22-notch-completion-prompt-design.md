# Notch Completion Prompt Design

Date: 2026-04-22
Project: ClaudeIsland
Status: Drafted, awaiting user review

## Problem

When a session finishes a task, ClaudeIsland already plays a completion sound, but the notch UI does not provide a strong visual confirmation. The current ready state is easy to miss, and it disappears too quickly to answer the user's most important glance question: **which session just finished?**

This creates a mismatch between audio and UI. Users hear that something completed, then look at the notch and get very little help understanding what finished.

## Goal

Add a lightweight completion prompt in the notch closed state that:

- Shows the most recently completed session
- Displays the existing session title
- Uses the existing pixel-art completion checkmark style
- Stays visible for about 2 to 3 seconds, target `2.5s`
- Feels like a continuation of the current notch activity system, not a separate notification framework

## Non-Goals

- No notification queue or rotation for multiple completed sessions
- No new session lifecycle phase in `SessionPhase`
- No new sound behavior
- No attempt to show the last tool/task summary instead of the session title
- No redesign of opened-notch chat UI

## Chosen Approach

Use the existing closed-notch activity pattern and add a dedicated **completion prompt** presentation on top of it.

Behavior:

- When a session transitions from `.processing` or `.compacting` to `.waitingForInput`, treat that as a just-finished event.
- Show a short closed-notch completion prompt.
- Display only the most recently completed session.
- If a new processing or approval state appears while the completion prompt is visible, that newer state wins immediately.

This is intentionally a light prompt, not a durable notification.

## UX Design

### Layout

In the closed notch state:

- Left: existing crab/activity area
- Center: `session.displayTitle`
- Right: existing `ReadyForInputIndicatorIcon`

The title is single-line only and truncates with ellipsis when needed.

### Timing

- Show completion prompt for `2.5s`
- Animate in smoothly from the current closed activity shape
- Animate out smoothly back to the default closed state

### Priority Rules

- `waitingForApproval` overrides completion prompt
- `processing` / `compacting` overrides completion prompt
- If another session finishes while the prompt is visible, replace the prompt content with the newer session instead of queueing

### Opened Notch Behavior

If the notch is already opened, do not introduce a second large visual layer. The completion prompt is primarily a closed-notch glance affordance.

## Architecture

### State Ownership

Do **not** add a new case to `SessionPhase`.

Reason: completion prompt is a transient UI effect, not a true session lifecycle state.

### Detection Layer

Detect the completion edge in `NotchView`, where the view already watches session changes and tracks short-lived ready indicators.

Likely integration point:

- `ClaudeIsland/UI/Views/NotchView.swift`

Specifically, the existing waiting-for-input transition handling should be extended so it can detect:

- previous phase-like presentation was busy (`.processing` or `.compacting`)
- new phase is `.waitingForInput`
- this transition has not already been surfaced as a completion prompt

### Presentation Layer

Extend `NotchActivityCoordinator` so it can represent transient completion presentation in the same orchestration layer that already manages expanding closed-notch activity.

Likely file:

- `ClaudeIsland/Core/NotchActivityCoordinator.swift`

The coordinator should carry enough display data for the completion prompt, including:

- activity type
- prompt title
- auto-hide duration

### Rendering Layer

Render the completion prompt inside the existing closed-notch header path.

Likely files:

- `ClaudeIsland/UI/Views/NotchView.swift`
- `ClaudeIsland/UI/Views/NotchHeaderView.swift`

The completion prompt should reuse:

- existing crab visual language
- existing `ReadyForInputIndicatorIcon`
- existing width expansion logic, with an additional bounded title region

## Edge Cases

### Duplicate Prompt Prevention

Do not re-show the completion prompt just because:

- session arrays reorder
- the view re-renders
- history reloads
- the same session remains in `.waitingForInput`

Only show when the session newly crosses from busy to ready.

### Long Titles

Clamp title width and truncate with ellipsis. The crab icon and completion icon must remain visible.

### Competing States

If a new approval prompt or processing activity begins while completion prompt is visible, dismiss completion prompt immediately.

### Multiple Completions

If several sessions finish close together, show only the latest one. No backlog, no carousel.

## Validation Plan

Manual verification:

1. Run a normal session and let it complete naturally
2. Confirm the closed notch shows session title + completion icon for about `2.5s`
3. Trigger a new prompt immediately after completion and confirm processing state takes over
4. Trigger a permission request during the completion window and confirm approval state takes priority
5. Test a long session title and confirm truncation is stable
6. Finish two sessions in short succession and confirm only the latest is shown

Build verification:

- `xcodebuild -project "ClaudeIsland.xcodeproj" -scheme "ClaudeIsland" -configuration Debug CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`

## Files Expected To Change

- `ClaudeIsland/Core/NotchActivityCoordinator.swift`
- `ClaudeIsland/UI/Views/NotchView.swift`
- `ClaudeIsland/UI/Views/NotchHeaderView.swift`

Possibly:

- a small helper or local state structure if needed for transient completion presentation

## Why This Design

This design solves the actual user problem with the smallest reasonable blast radius.

It keeps the real session lifecycle in `SessionStore` and `SessionPhase`, while adding the new behavior where it belongs: the notch presentation layer. That keeps the system easier to reason about and avoids turning a short-lived visual cue into another permanent app state.
