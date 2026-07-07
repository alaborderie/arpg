# 2. Godot renderer: Forward Mobile

- Status: accepted
- Date: 2026-07-07

## Context

Godot 4 offers three rendering methods: **Forward+** (desktop-class, Vulkan/Metal,
clustered lighting), **Forward Mobile** (Vulkan/Metal, tuned for phones), and
**Compatibility** (OpenGL ES 3 / WebGL, widest device reach incl. web). We target
desktop and mobile with deliberately light, low-poly, flat-shaded visuals, and want
it to look good on current phones without paying for features we don't use.

## Decision

Use **Forward Mobile** (`rendering_method="mobile"` in `project.godot`).

Rationale:

- It is the mobile-optimised path: good dynamic lighting and real-time shadows,
  which is what makes flat-shaded low-poly geometry read well, at a cost tuned for
  phone GPUs and thermals.
- Forward+ adds clustered lighting and desktop-oriented features we don't need for a
  flat-shaded look, at a higher baseline cost on mobile.
- It runs the same on desktop, so we develop and ship against one renderer.

## Consequences

- We drop support for very old, pre-Vulkan/Metal devices and for **web export**
  (which needs Compatibility).
- If broad low-end reach or a web build later becomes a priority, switching to
  Compatibility is essentially a one-line `rendering_method` change plus a visual
  re-test pass — cheap because our art is simple. That switch would get its own ADR.
