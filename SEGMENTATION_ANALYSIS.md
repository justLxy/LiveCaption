# Real-Time Segmentation Analysis & Refactoring

## Executive Summary

The current `Segmenter.swift` implementation has accumulated complexity through incremental patches. This document analyzes the issues and proposes a principled refactoring based on state machines and ASR signal prioritization.

## Problems with Current Implementation

### 1. Rule Accumulation Anti-Pattern

**Current state:**
- 150+ keywords across 4 lists: `dangling`, `fillers`, `conversationalOpeners`, `techAbbreviations`
- Special-case handlers: `"are"`, `"feel like if"`, `-ing` endings, subordinating conjunctions
- 120-line `canClose()` function with 15+ heuristics

**Why this is problematic:**
- Every edge case adds a new rule → maintenance nightmare
- Rules interact unpredictably (which takes priority?)
- No clear decision boundary between "complete" and "incomplete"
- Keyword blacklists don't capture actual grammar/semantics

### 2. Fragile State Management

**Current state:**
```swift
private var committedKeys: [String] = []
private var candidate = ""
private var candidateSince = Date.distantFuture
private var carry = ""
private var carrySince = Date.distantFuture
private(set) var revised = false
```

**Issues:**
- 5 separate state variables with implicit relationships
- `revised` flag set but never used (results discarded silently)
- No clear state transitions - hard to reason about correctness
- `candidate` vs `carry` distinction unclear

### 3. Timing Logic Issues

**Fixed thresholds:**
```swift
private static func waitTime(for text: String) -> TimeInterval {
    if tokenCount <= 4 { return 0.4 }
    if tokenCount <= 6 { return 0.5 }
    if hasComplexStructure && tokenCount > 10 { return 0.85 }
    // ...
}

mutating func flushCarry(...) -> [String] {
    let wait = Self.canClose(carry) ? 2.2 : 4.0
    // ...
}
```

**Problems:**
- Magic numbers (0.4s, 0.5s, 0.85s, 2.2s, 4.0s) - where do these come from?
- Doesn't adapt to actual speech patterns
- Timer checks every 0.15s but assumes precise intervals
- No consideration of pause duration from ASR

### 4. Under-Utilizing ASR Signals

**What we're missing:**
- ASR `final` events indicate natural pause points (user stopped speaking)
- Timing metadata in ASR events (audio duration, confidence scores if available)
- Distinction between confident finals vs tentative ones
- Natural speech rhythm information

**Current approach treats ASR as dumb text source:**
- `final` events trigger same keyword-based checks as partials
- All finals treated equally (short pause = long pause = sentence end)
- Ignores the fact that ASR already detected silence/pause

### 5. Semantic Completeness Heuristics

**Fundamental issue:** Trying to determine grammar completeness from keyword patterns

Examples of brittleness:
```swift
// This fails for: "The values are what we need" (complete sentence)
if last == "are" {
    if !text.lowercased().contains("values are") && tokens.count < 8 { return false }
}

// This fails for: "I feel like stopping" (complete sentence)
if (lower.contains("feel like if") || lower.contains("seems like if")), !tokens.contains("then") {
    return false
}
```

**Why keyword patterns fail:**
- English grammar is context-dependent
- Same word can be complete or incomplete depending on context
- Adding special cases for individual phrases doesn't scale

## Proposed Architecture

### Core Principle: State Machine + ASR Signal Priority

Instead of: "Check if text looks complete via keywords"
Use: "Trust ASR pause detection, use stability + light semantic checks"

### State Machine Design

```swift
enum State {
    case empty                              // No content
    case accumulating(buffer: String)       // Building from partials
    case stable(text: String, since: Date)  // Unchanged, waiting to commit
}
```

**Transitions:**
1. `empty` → `accumulating`: First partial arrives
2. `accumulating` → `stable`: Content stops changing
3. `stable` → `empty`: Content committed after stability window
4. Any state → `accumulating`: Content changes (ASR revision or new words)

### Decision Logic

**For partials (streaming):**
```
1. Has content changed since last partial?
   YES → Reset to accumulating
   NO → Check stability timer
   
2. Has content been stable for N seconds?
   NO → Wait
   YES → Light semantic check:
         - Very short (< 2 words)? Wait
         - Ends with obviously incomplete word ("a", "the", "and")? Wait
         - Otherwise → Commit
```

**For finals (pause detected):**
```
1. ASR detected pause → This is a natural boundary
2. Split at strong punctuation (.!?)
3. Submit complete segments
4. Hold remainder for next utterance
```

**Key insight:** `final` events are the PRIMARY signal. Semantic checks are tiebreakers for ambiguous partials only.

### Removed Complexity

**Delete entirely:**
- ❌ 150+ keyword lists
- ❌ `conversationalOpeners`, `techAbbreviations` 
- ❌ Special-case handlers for specific phrases
- ❌ Complex `waitTime()` with 6 thresholds
- ❌ `canClose()` with 15+ conditions

**Replace with:**
- ✅ Minimal incompleteness check (~10 words: "a", "the", "and", "or", "to", "of", "in", "is", "was", "are")
- ✅ Single stability threshold: 0.6s baseline
- ✅ Adaptive adjustment: ±30% based on length and punctuation
- ✅ State machine with explicit transitions

### Integration with AppModel

**Current flow:**
```swift
// Timer fires every 0.15s
private func checkStable() {
    if liveHypothesis.isEmpty {
        for text in segmenter.flushCarry() { enqueue(text) }
    } else {
        for text in segmenter.ingest(liveHypothesis, final:false) { enqueue(text) }
    }
    partial = segmenter.preview(liveHypothesis)
}
```

**With new design:**
```swift
private func checkStable() {
    // Unified tick() method handles both partial ingestion and timeout flushing
    for text in segmenter.tick(liveHypothesis: liveHypothesis) { 
        enqueue(text) 
    }
    partial = segmenter.preview(liveHypothesis)
}
```

## Expected Improvements

### 1. Stability
- Fewer edge cases → fewer bugs
- Explicit state machine → easier to debug
- ASR revisions handled gracefully → no duplicate/lost text

### 2. Naturalness
- Respects natural pause points (final events)
- Doesn't over-segment based on keywords
- Adapts timing to content (short vs long phrases)

### 3. Maintainability
- 1/3 the code size
- Clear decision logic
- No keyword lists to maintain

### 4. Performance
- Fewer string operations (no repeated tokenization)
- Simpler checks in hot path
- State transitions are O(1)

## Migration Strategy

### Phase 1: Parallel Testing
1. Keep current `Segmenter.swift`
2. Add new `SegmenterV2.swift`
3. Run both in test harness
4. Compare outputs on real lecture samples

### Phase 2: Validation
1. Metrics to track:
   - Segments per minute
   - Average segment length
   - User-perceived "naturalness" (qualitative)
   - Translation queue depth
2. A/B test with real usage
3. Collect failure cases

### Phase 3: Rollout
1. Switch default to V2
2. Keep V1 as fallback flag
3. Monitor for regressions
4. Remove V1 after 2 weeks stable

## Edge Cases to Test

### 1. Professor long continuous speech
```
Input: 50-word sentence with no pauses
Expected: Don't break mid-sentence even if no punctuation
```

### 2. ASR revision mid-sentence
```
Partial 1: "The gradient decent algorithm"
Partial 2: "The gradient descent algorithm converges"
Expected: No duplicate "gradient", submit full corrected text
```

### 3. Short interjections
```
"Um, okay, so..."
Expected: Don't submit as separate segments, wait for actual content
```

### 4. Question-answer pairs
```
"What is the derivative? It's the slope."
Expected: Two segments split at question mark
```

### 5. Technical abbreviations
```
"We use the API to access the ML model."
Expected: Don't break at "API." or "ML."
```

### 6. Silent gap (no speech)
```
5 seconds of silence after partial
Expected: Flush content even if incomplete-looking
```

## Conclusion

The current implementation works but has reached its complexity limit. Each new edge case requires another keyword or heuristic, making the system brittle and hard to maintain.

The proposed refactoring addresses root causes:
- **Use ASR signals properly** (finals = natural boundaries)
- **Explicit state machine** (clear transitions, easy to debug)
- **Minimal semantic checks** (10 words vs 150+)
- **Adaptive timing** (not fixed magic numbers)

This is a principled redesign, not another patch. The result will be more robust, maintainable, and natural-feeling.
