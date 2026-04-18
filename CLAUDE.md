# airassist — Project Conventions

## Phone-to-Mac file workflow

When I'm working with you from my phone via iMessage, I'll often drop new
files into this project from the Files app on iOS. Here's the convention:

### `_inbox/`
- Any new file I add from my phone lands here by default.
- When I say things like "the file I just added", "the screenshot I dropped",
  "the doc I sent over" — check this folder first, sorted by modification
  time (newest first).
- Once you've processed a file from `_inbox/`, move it to its proper home
  (or delete it if it was one-off context).

### `screenshots/`
- UI references, design inspiration, error screenshots.
- I may drop these from my phone when I want you to match a style or
  debug something visual.

## Working style when I'm on phone

- I'll often give brief, terse instructions on iMessage. If something's
  ambiguous, make a reasonable assumption and tell me what you assumed
  rather than stacking up clarifying questions.
- When you finish a task, give me a 1-2 sentence summary of what changed.
  Don't recap the whole diff — I'll check when I'm back at the Mac.
- If you hit a real blocker (not a minor question), stop and tell me.
- Keep replies short. Long messages get truncated or split awkwardly on iOS.

## Commands I commonly use from phone

- "check inbox" → look at `_inbox/` and tell me what's there
- "process inbox" → deal with everything in `_inbox/` (move files to right
  places, integrate content into the project, then clear the folder)
- "what's the status" → what was I last working on, what's pending
- "commit and push" → git commit -am with a sensible message, then push

## Project-specific notes

<!-- Add anything specific to this project below: stack, entry points,
     key files, gotchas, etc. Claude will read this on every session. -->
