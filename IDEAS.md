# Ideas

## Window-group frames

Selecting several windows and arranging them into a workspace that can be easily recalled is an essential feature. As it stands, the current functionality if Expanse tends to break workspace layouts, so it's really only useful and reliable enough for zooming between full window apps. To solve this, we need to introduce a concept of a "frame"/container.

**frames** are named, persistent regions of the canvas that wrap related windows and remember their own camera view. A frame could be opened like a single destination,
letting a person return to a preconfigured layout without choosing a new focused window first.

Possible frame types:

- **Freeform frame:** simplest frame: an ordinary bounded group that preserves the windows' positions.
- **Tab frame:** a vertical or horizontal frame with tabs. Maybe could study the code from this project to integrate https://github.com/ZimengXiong/tabbed
- **Horizontal scrolling frame:** a strip of related windows with its own horizontal windowed scrolling viewport. Like Niri.
- (less important) **BSP frame:** a DSP/dwindling layout that assigns windows to a structured tiling tree.

This is intentionally a design note, not a commitment to a layout model. The first useful milestone
would be a freeform frame created from the current selection and reopened at its saved camera view.
