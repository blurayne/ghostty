pub const sfnt = @import("opentype/sfnt.zig");

const svg = @import("opentype/svg.zig");
const os2 = @import("opentype/os2.zig");
const post = @import("opentype/post.zig");
const hhea = @import("opentype/hhea.zig");
const head = @import("opentype/head.zig");
const glyf = @import("opentype/glyf.zig");
const colr = @import("opentype/colr.zig");
const cpal = @import("opentype/cpal.zig");

pub const SVG = svg.SVG;
pub const OS2 = os2.OS2;
pub const Post = post.Post;
pub const Hhea = hhea.Hhea;
pub const Head = head.Head;
pub const Glyf = glyf.Glyf;
pub const Colr = colr.Colr;
pub const Cpal = cpal.Cpal;

test {
    @import("std").testing.refAllDecls(@This());
}
