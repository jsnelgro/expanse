# Ideas

## Window-group frames

Selecting several windows and fitting the selection is useful for arranging work, but it does not
create a durable view. Returning to that group still requires choosing one app, which recenters the
camera on that app rather than restoring the side-by-side composition.

Explore **frames** (or containers): named, persistent regions of the canvas that wrap related
windows and remember their own camera view. A frame could be opened like a single destination,
letting a person return to a preconfigured layout without choosing a new focused window first.

Possible frame types:

- **Tab frame:** a vertical or horizontally frame with tabs. Maybe could study the code from to integrate https://github.com/ZimengXiong/tabbed
- **Freeform frame:** an ordinary bounded group that preserves the windows' positions.
- **Horizontal scrolling frame:** a strip of related windows with its own horizontal viewport.
- (less important) **BSP frame:** a DSP/dwindling layout that assigns windows to a structured tiling tree.

This is intentionally a design note, not a commitment to a layout model. The first useful milestone
would be a freeform frame created from the current selection and reopened at its saved camera view.
