/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */
/*
 * MMAtsuiTextView
 *
 * Dispatches keyboard and mouse input to the backend.  Handles drag-n-drop of
 * files onto window.  The rendering is done using ATSUI.
 *
 * The text view area consists of two parts:
 *   1. The text area - this is where text is rendered; the size is governed by
 *      the current number of rows and columns.
 *   2. The inset area - this is a border around the text area; the size is
 *      governed by the user defaults MMTextInset[Left|Right|Top|Bottom].
 *
 * The current size of the text view frame does not always match the desired
 * area, i.e. the area determined by the number of rows, columns plus text
 * inset.  This distinction is particularly important when the view is being
 * resized.
 */

#import "MMAppController.h"
#import "MMAtsuiTextView.h"
#import "MMTextViewHelper.h"
#import "MMVimController.h"
#import "MMWindowController.h"
#import "Miscellaneous.h"


// TODO: What does DRAW_TRANSP flag do?  If the background isn't drawn when
// this flag is set, then sometimes the character after the cursor becomes
// blank.  Everything seems to work fine by just ignoring this flag.
#define DRAW_TRANSP               0x01    /* draw with transparant bg */
#define DRAW_BOLD                 0x02    /* draw bold text */
#define DRAW_UNDERL               0x04    /* draw underline text */
#define DRAW_UNDERC               0x08    /* draw undercurl text */
#define DRAW_ITALIC               0x10    /* draw italic text */
#define DRAW_CURSOR               0x20

#define kUnderlineOffset            (-2)
#define kUnderlineHeight            1
#define kUndercurlHeight            2
#define kUndercurlOffset            (-2)
#define kUndercurlDotWidth          2
#define kUndercurlDotDistance       2


@interface NSFont (AppKitPrivate)
- (ATSUFontID) _atsFontID;
@end


@interface MMAtsuiTextView (Private)
- (void)initAtsuStyles;
- (void)disposeAtsuStyles;
- (void)updateAtsuStyles;
- (MMWindowController *)windowController;
- (MMVimController *)vimController;
@end


@interface MMAtsuiTextView (Drawing)
- (NSPoint)originForRow:(int)row column:(int)column;
- (NSRect)rectFromRow:(int)row1 column:(int)col1
                toRow:(int)row2 column:(int)col2;
- (NSSize)textAreaSize;
- (void)resizeContentImage;
- (void)beginDrawing;
- (void)endDrawing;
- (void)drawString:(UniChar *)string length:(UniCharCount)length
             atRow:(int)row column:(int)col cells:(int)cells
         withFlags:(int)flags foregroundColor:(NSColor *)fg
   backgroundColor:(NSColor *)bg specialColor:(NSColor *)sp;
- (void)deleteLinesFromRow:(int)row lineCount:(int)count
              scrollBottom:(int)bottom left:(int)left right:(int)right
                     color:(NSColor *)color;
- (void)insertLinesAtRow:(int)row lineCount:(int)count
            scrollBottom:(int)bottom left:(int)left right:(int)right
                   color:(NSColor *)color;
- (void)clearBlockFromRow:(int)row1 column:(int)col1 toRow:(int)row2
                   column:(int)col2 color:(NSColor *)color;
- (void)clearAll;
- (void)drawInsertionPointAtRow:(int)row column:(int)col shape:(int)shape
                       fraction:(int)percent color:(NSColor *)color;
- (void)drawInvertedRectAtRow:(int)row column:(int)col numRows:(int)nrows
                   numColumns:(int)ncols;
@end



    static float
defaultLineHeightForFont(NSFont *font)
{
    // HACK: -[NSFont defaultLineHeightForFont] is deprecated but since the
    // ATSUI renderer does not use NSLayoutManager we create one temporarily.
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    float height = [lm defaultLineHeightForFont:font];
    [lm release];

    return height;
}

@implementation MMAtsuiTextView

- (id)initWithFrame:(NSRect)frame
{
    if (!(self = [super initWithFrame:frame]))
        return nil;

    // NOTE!  It does not matter which font is set here, Vim will set its
    // own font on startup anyway.  Just set some bogus values.
    font = [[NSFont userFixedPitchFontOfSize:0] retain];
    ascender = 0;
    cellSize.width = cellSize.height = 1;
    contentImage = nil;
    imageSize = NSZeroSize;
    insetSize = NSZeroSize;

    // NOTE: If the default changes to 'NO' then the intialization of
    // p_antialias in option.c must change as well.
    antialias = YES;

    helper = [[MMTextViewHelper alloc] init];
    [helper setTextView:self];

    [self initAtsuStyles];

    [self registerForDraggedTypes:[NSArray arrayWithObjects:
            NSFilenamesPboardType, NSStringPboardType, nil]];

    return self;
}

- (void)dealloc
{
    [self disposeAtsuStyles];
    [font release];  font = nil;
    [defaultBackgroundColor release];  defaultBackgroundColor = nil;
    [defaultForegroundColor release];  defaultForegroundColor = nil;

    [helper setTextView:nil];
    [helper dealloc];  helper = nil;

    [super dealloc];
}

- (int)maxRows
{
    return maxRows;
}

- (void)getMaxRows:(int*)rows columns:(int*)cols
{
    if (rows) *rows = maxRows;
    if (cols) *cols = maxColumns;
}

- (void)setMaxRows:(int)rows columns:(int)cols
{
    // NOTE: Just remember the new values, the actual resizing is done lazily.
    maxRows = rows;
    maxColumns = cols;
}

- (void)setDefaultColorsBackground:(NSColor *)bgColor
                        foreground:(NSColor *)fgColor
{
    if (defaultBackgroundColor != bgColor) {
        [defaultBackgroundColor release];
        defaultBackgroundColor = bgColor ? [bgColor retain] : nil;
    }

    // NOTE: The default foreground color isn't actually used for anything, but
    // other class instances might want to be able to access it so it is stored
    // here.
    if (defaultForegroundColor != fgColor) {
        [defaultForegroundColor release];
        defaultForegroundColor = fgColor ? [fgColor retain] : nil;
    }
}

- (void)setTextContainerInset:(NSSize)size
{
    insetSize = size;
}

- (NSRect)rectForRowsInRange:(NSRange)range
{
    NSRect rect = { 0, 0, 0, 0 };
    unsigned start = range.location > maxRows ? maxRows : range.location;
    unsigned length = range.length;

    if (start + length > maxRows)
        length = maxRows - start;

    rect.origin.y = cellSize.height * start + insetSize.height;
    rect.size.height = cellSize.height * length;

    return rect;
}

- (NSRect)rectForColumnsInRange:(NSRange)range
{
    NSRect rect = { 0, 0, 0, 0 };
    unsigned start = range.location > maxColumns ? maxColumns : range.location;
    unsigned length = range.length;

    if (start+length > maxColumns)
        length = maxColumns - start;

    rect.origin.x = cellSize.width * start + insetSize.width;
    rect.size.width = cellSize.width * length;

    return rect;
}


- (void)setFont:(NSFont *)newFont
{
    if (newFont && font != newFont) {
        [font release];
        font = [newFont retain];
        ascender = roundf([font ascender]);

        float em = [@"m" sizeWithAttributes:
                [NSDictionary dictionaryWithObject:newFont
                                            forKey:NSFontAttributeName]].width;
        float cellWidthMultiplier = [[NSUserDefaults standardUserDefaults]
                floatForKey:MMCellWidthMultiplierKey];

        // NOTE! Even though NSFontFixedAdvanceAttribute is a float, it will
        // only render at integer sizes.  Hence, we restrict the cell width to
        // an integer here, otherwise the window width and the actual text
        // width will not match.
        cellSize.width = ceilf(em * cellWidthMultiplier);
        cellSize.height = linespace + defaultLineHeightForFont(newFont);

        [self updateAtsuStyles];
    }
}

- (void)setWideFont:(NSFont *)newFont
{
}

- (NSFont *)font
{
    return font;
}

- (NSSize)cellSize
{
    return cellSize;
}

- (void)setLinespace:(float)newLinespace
{
    linespace = newLinespace;

    // NOTE: The linespace is added to the cell height in order for a multiline
    // selection not to have white (background color) gaps between lines.  Also
    // this simplifies the code a lot because there is no need to check the
    // linespace when calculating the size of the text view etc.  When the
    // linespace is non-zero the baseline will be adjusted as well; check
    // MMTypesetter.
    cellSize.height = linespace + defaultLineHeightForFont(font);
}




- (void)setShouldDrawInsertionPoint:(BOOL)on
{
}

- (void)setPreEditRow:(int)row column:(int)col
{
}

- (void)hideMarkedTextField
{
}

- (void)setMouseShape:(int)shape
{
    [helper setMouseShape:shape];
}

- (void)setAntialias:(BOOL)state
{
    antialias = state;
}




- (void)keyDown:(NSEvent *)event
{
    [helper keyDown:event];
}

- (void)insertText:(id)string
{
    [helper insertText:string];
}

- (void)doCommandBySelector:(SEL)selector
{
    [helper doCommandBySelector:selector];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    return [helper performKeyEquivalent:event];
}

- (BOOL)hasMarkedText
{
    return NO;
}

- (void)unmarkText
{
}

- (void)scrollWheel:(NSEvent *)event
{
    [helper scrollWheel:event];
}

- (void)mouseDown:(NSEvent *)event
{
    [helper mouseDown:event];
}

- (void)rightMouseDown:(NSEvent *)event
{
    [helper mouseDown:event];
}

- (void)otherMouseDown:(NSEvent *)event
{
    [helper mouseDown:event];
}

- (void)mouseUp:(NSEvent *)event
{
    [helper mouseUp:event];
}

- (void)rightMouseUp:(NSEvent *)event
{
    [helper mouseUp:event];
}

- (void)otherMouseUp:(NSEvent *)event
{
    [helper mouseUp:event];
}

- (void)mouseDragged:(NSEvent *)event
{
    [helper mouseDragged:event];
}

- (void)rightMouseDragged:(NSEvent *)event
{
    [helper mouseDragged:event];
}

- (void)otherMouseDragged:(NSEvent *)event
{
    [helper mouseDragged:event];
}

- (void)mouseMoved:(NSEvent *)event
{
    [helper mouseMoved:event];
}

- (void)mouseEntered:(NSEvent *)event
{
    [helper mouseEntered:event];
}

- (void)mouseExited:(NSEvent *)event
{
    [helper mouseExited:event];
}

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    [helper setFrame:frame];
}

- (void)viewDidMoveToWindow
{
    [helper viewDidMoveToWindow];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow
{
    [helper viewWillMoveToWindow:newWindow];
}

- (NSMenu*)menuForEvent:(NSEvent *)event
{
    // HACK! Return nil to disable default popup menus (Vim provides its own).
    // Called when user Ctrl-clicks in the view (this is already handled in
    // rightMouseDown:).
    return nil;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    return [helper performDragOperation:sender];
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    return [helper draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return [helper draggingUpdated:sender];
}



- (BOOL)mouseDownCanMoveWindow
{
    return NO;
}

- (BOOL)isOpaque
{
    return YES;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)isFlipped
{
    return NO;
}

- (void)drawRect:(NSRect)rect
{
    [defaultBackgroundColor set];
    NSRectFill(rect);

    NSPoint pt = { insetSize.width, insetSize.height };
    [contentImage compositeToPoint:pt operation:NSCompositeCopy];
}

- (BOOL) wantsDefaultClipping
{
    return NO;
}


#define MM_DEBUG_DRAWING 0

- (void)performBatchDrawWithData:(NSData *)data
{
    const void *bytes = [data bytes];
    const void *end = bytes + [data length];

    if (! NSEqualSizes(imageSize, [self textAreaSize]))
        [self resizeContentImage];

#if MM_DEBUG_DRAWING
    NSLog(@"====> BEGIN %s", _cmd);
#endif
    [self beginDrawing];

    // TODO: Sanity check input

    while (bytes < end) {
        int type = *((int*)bytes);  bytes += sizeof(int);

        if (ClearAllDrawType == type) {
#if MM_DEBUG_DRAWING
            NSLog(@"   Clear all");
#endif
            [self clearAll];
        } else if (ClearBlockDrawType == type) {
            unsigned color = *((unsigned*)bytes);  bytes += sizeof(unsigned);
            int row1 = *((int*)bytes);  bytes += sizeof(int);
            int col1 = *((int*)bytes);  bytes += sizeof(int);
            int row2 = *((int*)bytes);  bytes += sizeof(int);
            int col2 = *((int*)bytes);  bytes += sizeof(int);

#if MM_DEBUG_DRAWING
            NSLog(@"   Clear block (%d,%d) -> (%d,%d)", row1, col1,
                    row2,col2);
#endif
            [self clearBlockFromRow:row1 column:col1
                    toRow:row2 column:col2
                    color:[NSColor colorWithArgbInt:color]];
        } else if (DeleteLinesDrawType == type) {
            unsigned color = *((unsigned*)bytes);  bytes += sizeof(unsigned);
            int row = *((int*)bytes);  bytes += sizeof(int);
            int count = *((int*)bytes);  bytes += sizeof(int);
            int bot = *((int*)bytes);  bytes += sizeof(int);
            int left = *((int*)bytes);  bytes += sizeof(int);
            int right = *((int*)bytes);  bytes += sizeof(int);

#if MM_DEBUG_DRAWING
            NSLog(@"   Delete %d line(s) from %d", count, row);
#endif
            [self deleteLinesFromRow:row lineCount:count
                    scrollBottom:bot left:left right:right
                           color:[NSColor colorWithArgbInt:color]];
        } else if (DrawStringDrawType == type) {
            int bg = *((int*)bytes);  bytes += sizeof(int);
            int fg = *((int*)bytes);  bytes += sizeof(int);
            int sp = *((int*)bytes);  bytes += sizeof(int);
            int row = *((int*)bytes);  bytes += sizeof(int);
            int col = *((int*)bytes);  bytes += sizeof(int);
            int cells = *((int*)bytes);  bytes += sizeof(int);
            int flags = *((int*)bytes);  bytes += sizeof(int);
            int len = *((int*)bytes);  bytes += sizeof(int);
            // UniChar *string = (UniChar*)bytes;  bytes += len;
            NSString *string = [[NSString alloc]
                    initWithBytesNoCopy:(void*)bytes
                                 length:len
                               encoding:NSUTF8StringEncoding
                           freeWhenDone:NO];
            bytes += len;
#if MM_DEBUG_DRAWING
            NSLog(@"   Draw string at (%d,%d) length=%d flags=%d fg=0x%x "
                    "bg=0x%x sp=0x%x", row, col, len, flags, fg, bg, sp);
#endif
            unichar *characters = malloc(sizeof(unichar) * [string length]);
            [string getCharacters:characters];

            [self drawString:characters
                             length:[string length]
                              atRow:row
                             column:col
                              cells:cells withFlags:flags
                    foregroundColor:[NSColor colorWithRgbInt:fg]
                    backgroundColor:[NSColor colorWithArgbInt:bg]
                       specialColor:[NSColor colorWithRgbInt:sp]];
            free(characters);
            [string release];
        } else if (InsertLinesDrawType == type) {
            unsigned color = *((unsigned*)bytes);  bytes += sizeof(unsigned);
            int row = *((int*)bytes);  bytes += sizeof(int);
            int count = *((int*)bytes);  bytes += sizeof(int);
            int bot = *((int*)bytes);  bytes += sizeof(int);
            int left = *((int*)bytes);  bytes += sizeof(int);
            int right = *((int*)bytes);  bytes += sizeof(int);

#if MM_DEBUG_DRAWING
            NSLog(@"   Insert %d line(s) at row %d", count, row);
#endif
            [self insertLinesAtRow:row lineCount:count
                             scrollBottom:bot left:left right:right
                                    color:[NSColor colorWithArgbInt:color]];
        } else if (DrawCursorDrawType == type) {
            unsigned color = *((unsigned*)bytes);  bytes += sizeof(unsigned);
            int row = *((int*)bytes);  bytes += sizeof(int);
            int col = *((int*)bytes);  bytes += sizeof(int);
            int shape = *((int*)bytes);  bytes += sizeof(int);
            int percent = *((int*)bytes);  bytes += sizeof(int);

#if MM_DEBUG_DRAWING
            NSLog(@"   Draw cursor at (%d,%d)", row, col);
#endif
            [self drawInsertionPointAtRow:row column:col shape:shape
                                     fraction:percent
                                        color:[NSColor colorWithRgbInt:color]];
        } else if (DrawInvertedRectDrawType == type) {
            int row = *((int*)bytes);  bytes += sizeof(int);
            int col = *((int*)bytes);  bytes += sizeof(int);
            int nr = *((int*)bytes);  bytes += sizeof(int);
            int nc = *((int*)bytes);  bytes += sizeof(int);
            /*int invert = *((int*)bytes);*/  bytes += sizeof(int);

#if MM_DEBUG_DRAWING
            NSLog(@"   Draw inverted rect: row=%d col=%d nrows=%d ncols=%d",
                    row, col, nr, nc);
#endif
            [self drawInvertedRectAtRow:row column:col numRows:nr
                             numColumns:nc];
        } else if (SetCursorPosDrawType == type) {
            // TODO: This is used for Voice Over support in MMTextView,
            // MMAtsuiTextView currently does not support Voice Over.
            /*cursorRow = *((int*)bytes);*/  bytes += sizeof(int);
            /*cursorCol = *((int*)bytes);*/  bytes += sizeof(int);
        } else {
            NSLog(@"WARNING: Unknown draw type (type=%d)", type);
        }
    }

    [self endDrawing];

    // NOTE: During resizing, Cocoa only sends draw messages before Vim's rows
    // and columns are changed (due to ipc delays). Force a redraw here.
    [self setNeedsDisplay:YES];
    // [self displayIfNeeded];

#if MM_DEBUG_DRAWING
    NSLog(@"<==== END   %s", _cmd);
#endif
}

- (NSSize)constrainRows:(int *)rows columns:(int *)cols toSize:(NSSize)size
{
    // TODO:
    // - Rounding errors may cause size change when there should be none
    // - Desired rows/columns shold not be 'too small'

    // Constrain the desired size to the given size.  Values for the minimum
    // rows and columns is taken from Vim.
    NSSize desiredSize = [self desiredSize];
    int desiredRows = maxRows;
    int desiredCols = maxColumns;

    if (size.height != desiredSize.height) {
        float fh = cellSize.height;
        float ih = 2 * insetSize.height;
        if (fh < 1.0f) fh = 1.0f;

        desiredRows = floor((size.height - ih)/fh);
        desiredSize.height = fh*desiredRows + ih;
    }

    if (size.width != desiredSize.width) {
        float fw = cellSize.width;
        float iw = 2 * insetSize.width;
        if (fw < 1.0f) fw = 1.0f;

        desiredCols = floor((size.width - iw)/fw);
        desiredSize.width = fw*desiredCols + iw;
    }

    if (rows) *rows = desiredRows;
    if (cols) *cols = desiredCols;

    return desiredSize;
}

- (NSSize)desiredSize
{
    // Compute the size the text view should be for the entire text area and
    // inset area to be visible with the present number of rows and columns.
    return NSMakeSize(maxColumns * cellSize.width + 2 * insetSize.width,
                      maxRows * cellSize.height + 2 * insetSize.height);
}

- (NSSize)minSize
{
    // Compute the smallest size the text view is allowed to be.
    return NSMakeSize(MMMinColumns * cellSize.width + 2 * insetSize.width,
                      MMMinRows * cellSize.height + 2 * insetSize.height);
}

- (void)changeFont:(id)sender
{
    NSFont *newFont = [sender convertFont:font];

    if (newFont) {
        NSString *name = [newFont displayName];
        unsigned len = [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        if (len > 0) {
            NSMutableData *data = [NSMutableData data];
            float pointSize = [newFont pointSize];

            [data appendBytes:&pointSize length:sizeof(float)];

            ++len;  // include NUL byte
            [data appendBytes:&len length:sizeof(unsigned)];
            [data appendBytes:[name UTF8String] length:len];

            [[self vimController] sendMessage:SetFontMsgID data:data];
        }
    }
}


//
// NOTE: The menu items cut/copy/paste/undo/redo/select all/... must be bound
// to the same actions as in IB otherwise they will not work with dialogs.  All
// we do here is forward these actions to the Vim process.
//
- (IBAction)cut:(id)sender
{
    [[self windowController] vimMenuItemAction:sender];
}

- (IBAction)copy:(id)sender
{
    [[self windowController] vimMenuItemAction:sender];
}

- (IBAction)paste:(id)sender
{
    [[self windowController] vimMenuItemAction:sender];
}

- (IBAction)undo:(id)sender
{
    [[self windowController] vimMenuItemAction:sender];
}

- (IBAction)redo:(id)sender
{
    [[self windowController] vimMenuItemAction:sender];
}

- (IBAction)selectAll:(id)sender
{
    [[self windowController] vimMenuItemAction:sender];
}

- (BOOL)convertPoint:(NSPoint)point toRow:(int *)row column:(int *)column
{
    // View is not flipped, instead the atsui code draws to a flipped image;
    // thus we need to 'flip' the coordinate here since the column number
    // increases in an up-to-down order.
    point.y = [self frame].size.height - point.y;

    NSPoint origin = { insetSize.width, insetSize.height };

    if (!(cellSize.width > 0 && cellSize.height > 0))
        return NO;

    if (row) *row = floor((point.y-origin.y-1) / cellSize.height);
    if (column) *column = floor((point.x-origin.x-1) / cellSize.width);

    //NSLog(@"convertPoint:%@ toRow:%d column:%d", NSStringFromPoint(point),
    //        *row, *column);

    return YES;
}

@end // MMAtsuiTextView




@implementation MMAtsuiTextView (Private)

- (void)initAtsuStyles
{
    int i;
    for (i = 0; i < MMMaxCellsPerChar; i++)
        ATSUCreateStyle(&atsuStyles[i]);
}

- (void)disposeAtsuStyles
{
    int i;

    for (i = 0; i < MMMaxCellsPerChar; i++)
        if (atsuStyles[i] != NULL)
        {
            if (ATSUDisposeStyle(atsuStyles[i]) != noErr)
                atsuStyles[i] = NULL;
        }
}

- (void)updateAtsuStyles
{
    ATSUFontID        fontID;
    Fixed             fontSize;
    Fixed             fontWidth;
    int               i;
    CGAffineTransform transform = CGAffineTransformMakeScale(1, -1);
    ATSStyleRenderingOptions options;

    fontID    = [font _atsFontID];
    fontSize  = Long2Fix([font pointSize]);
    options   = kATSStyleApplyAntiAliasing;

    ATSUAttributeTag attribTags[] =
    {
        kATSUFontTag, kATSUSizeTag, kATSUImposeWidthTag,
        kATSUFontMatrixTag, kATSUStyleRenderingOptionsTag,
        kATSUMaxATSUITagValue + 1
    };

    ByteCount attribSizes[] =
    {
        sizeof(ATSUFontID), sizeof(Fixed), sizeof(fontWidth),
        sizeof(CGAffineTransform), sizeof(ATSStyleRenderingOptions),
        sizeof(font)
    };

    ATSUAttributeValuePtr attribValues[] =
    {
        &fontID, &fontSize, &fontWidth, &transform, &options, &font
    };

    ATSUFontFeatureType featureTypes[] = {
        kLigaturesType, kLigaturesType
    };

    ATSUFontFeatureSelector featureSelectors[] = {
        kCommonLigaturesOffSelector, kRareLigaturesOffSelector
    };

    for (i = 0; i < MMMaxCellsPerChar; i++)
    {
        fontWidth = Long2Fix(cellSize.width * (i + 1));

        if (ATSUSetAttributes(atsuStyles[i],
                              (sizeof attribTags) / sizeof(ATSUAttributeTag),
                              attribTags, attribSizes, attribValues) != noErr)
        {
            ATSUDisposeStyle(atsuStyles[i]);
            atsuStyles[i] = NULL;
        }

        // Turn off ligatures by default
        ATSUSetFontFeatures(atsuStyles[i],
                            sizeof(featureTypes) / sizeof(featureTypes[0]),
                            featureTypes, featureSelectors);
    }
}

- (MMWindowController *)windowController
{
    id windowController = [[self window] windowController];
    if ([windowController isKindOfClass:[MMWindowController class]])
        return (MMWindowController*)windowController;
    return nil;
}

- (MMVimController *)vimController
{
    return [[self windowController] vimController];
}

@end // MMAtsuiTextView (Private)




@implementation MMAtsuiTextView (Drawing)

- (NSPoint)originForRow:(int)row column:(int)col
{
    return NSMakePoint(col * cellSize.width, row * cellSize.height);
}

- (NSRect)rectFromRow:(int)row1 column:(int)col1
                toRow:(int)row2 column:(int)col2
{
    NSPoint origin = [self originForRow: row1 column: col1];
    return NSMakeRect(origin.x, origin.y,
                      (col2 + 1 - col1) * cellSize.width,
                      (row2 + 1 - row1) * cellSize.height);
}

- (NSSize)textAreaSize
{
    // Calculate the (desired) size of the text area, i.e. the text view area
    // minus the inset area.
    return NSMakeSize(maxColumns * cellSize.width, maxRows * cellSize.height);
}

- (void)resizeContentImage
{
    //NSLog(@"resizeContentImage");
    [contentImage release];
    contentImage = [[NSImage alloc] initWithSize:[self textAreaSize]];
    [contentImage setFlipped: YES];
    imageSize = [self textAreaSize];
}

- (void)beginDrawing
{
    [contentImage lockFocus];
}

- (void)endDrawing
{
    [contentImage unlockFocus];
}

#define atsu_style_set_bool(s, t, b) \
    ATSUSetAttributes(s, 1, &t, &(sizeof(Boolean)), &&b);
#define FILL_Y(y)    (y * cellSize.height)

- (void)drawString:(UniChar *)string length:(UniCharCount)length
             atRow:(int)row column:(int)col cells:(int)cells
         withFlags:(int)flags foregroundColor:(NSColor *)fg
   backgroundColor:(NSColor *)bg specialColor:(NSColor *)sp
{
    // 'string' consists of 'length' utf-16 code pairs and should cover 'cells'
    // display cells (a normal character takes up one display cell, a wide
    // character takes up two)
    ATSUStyle       style = (flags & DRAW_WIDE) ? atsuStyles[1] : atsuStyles[0];
    ATSUTextLayout  layout;

    // Font selection and rendering options for ATSUI
    ATSUAttributeTag      attribTags[3] = { kATSUQDBoldfaceTag,
                                            kATSUFontMatrixTag,
                                            kATSUStyleRenderingOptionsTag };

    ByteCount             attribSizes[] = { sizeof(Boolean),
                                            sizeof(CGAffineTransform),
                                            sizeof(UInt32) };
    Boolean               useBold;
    CGAffineTransform     theTransform = CGAffineTransformMakeScale(1.0, -1.0);
    UInt32                useAntialias;

    ATSUAttributeValuePtr attribValues[3] = { &useBold, &theTransform,
                                              &useAntialias };

    useBold      = (flags & DRAW_BOLD) ? true : false;

    if (flags & DRAW_ITALIC)
        theTransform.c = Fix2X(kATSItalicQDSkew);

    useAntialias = antialias ? kATSStyleApplyAntiAliasing
                             : kATSStyleNoAntiAliasing;

    ATSUSetAttributes(style, sizeof(attribValues) / sizeof(attribValues[0]),
                      attribTags, attribSizes, attribValues);

    // NSLog(@"drawString: %d", length);

    ATSUCreateTextLayout(&layout);
    ATSUSetTextPointerLocation(layout, string,
                               kATSUFromTextBeginning, kATSUToTextEnd,
                               length);
    ATSUSetRunStyle(layout, style, kATSUFromTextBeginning, kATSUToTextEnd);

    NSRect rect = NSMakeRect(col * cellSize.width, row * cellSize.height,
                             length * cellSize.width, cellSize.height);
    if (flags & DRAW_WIDE)
        rect.size.width = rect.size.width * 2;
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];

    ATSUAttributeTag tags[] = { kATSUCGContextTag };
    ByteCount sizes[] = { sizeof(CGContextRef) };
    ATSUAttributeValuePtr values[] = { &context };
    ATSUSetLayoutControls(layout, 1, tags, sizes, values);

    if (! (flags & DRAW_TRANSP))
    {
        [bg set];
        NSRectFill(rect);
    }

    [fg set];

    ATSUSetTransientFontMatching(layout, TRUE);
    ATSUDrawText(layout,
                 kATSUFromTextBeginning,
                 kATSUToTextEnd,
                 X2Fix(rect.origin.x),
                 X2Fix(rect.origin.y + ascender));
    ATSUDisposeTextLayout(layout);

    if (flags & DRAW_UNDERL)
    {
        [fg set];
        NSRectFill(NSMakeRect(rect.origin.x,
                              (row + 1) * cellSize.height + kUnderlineOffset,
                              rect.size.width, kUnderlineHeight));
    }

    if (flags & DRAW_UNDERC)
    {
        [sp set];

        float line_end_x = rect.origin.x + rect.size.width;
        int i = 0;
        NSRect line_rect = NSMakeRect(
                rect.origin.x,
                (row + 1) * cellSize.height + kUndercurlOffset,
                kUndercurlDotWidth, kUndercurlHeight);

        while (line_rect.origin.x < line_end_x)
        {
            if (i % 2)
                NSRectFill(line_rect);

            line_rect.origin.x += kUndercurlDotDistance;
            i++;
        }
    }
}

- (void)scrollRect:(NSRect)rect lineCount:(int)count
{
    NSPoint destPoint = rect.origin;
    destPoint.y += count * cellSize.height;

    NSCopyBits(0, rect, destPoint);
}

- (void)deleteLinesFromRow:(int)row lineCount:(int)count
              scrollBottom:(int)bottom left:(int)left right:(int)right
                     color:(NSColor *)color
{
    NSRect rect = [self rectFromRow:row + count
                             column:left
                              toRow:bottom
                             column:right];
    [color set];
    // move rect up for count lines
    [self scrollRect:rect lineCount:-count];
    [self clearBlockFromRow:bottom - count + 1
                     column:left
                      toRow:bottom
                     column:right
                      color:color];
}

- (void)insertLinesAtRow:(int)row lineCount:(int)count
            scrollBottom:(int)bottom left:(int)left right:(int)right
                   color:(NSColor *)color
{
    NSRect rect = [self rectFromRow:row
                             column:left
                              toRow:bottom - count
                             column:right];
    [color set];
    // move rect down for count lines
    [self scrollRect:rect lineCount:count];
    [self clearBlockFromRow:row
                     column:left
                      toRow:row + count - 1
                     column:right
                      color:color];
}

- (void)clearBlockFromRow:(int)row1 column:(int)col1 toRow:(int)row2
                   column:(int)col2 color:(NSColor *)color
{
    [color set];
    NSRectFill([self rectFromRow:row1 column:col1 toRow:row2 column:col2]);
}

- (void)clearAll
{
    [defaultBackgroundColor set];
    NSRectFill(NSMakeRect(0, 0, imageSize.width, imageSize.height));
}

- (void)drawInsertionPointAtRow:(int)row column:(int)col shape:(int)shape
                       fraction:(int)percent color:(NSColor *)color
{
    NSPoint origin = [self originForRow:row column:col];
    NSRect rect = NSMakeRect(origin.x, origin.y,
                             cellSize.width, cellSize.height);

    // NSLog(@"shape = %d, fraction: %d", shape, percent);

    if (MMInsertionPointHorizontal == shape) {
        int frac = (cellSize.height * percent + 99)/100;
        rect.origin.y += rect.size.height - frac;
        rect.size.height = frac;
    } else if (MMInsertionPointVertical == shape) {
        int frac = (cellSize.width * percent + 99)/100;
        rect.size.width = frac;
    } else if (MMInsertionPointVerticalRight == shape) {
        int frac = (cellSize.width * percent + 99)/100;
        rect.origin.x += rect.size.width - frac;
        rect.size.width = frac;
    }

    [color set];
    if (MMInsertionPointHollow == shape) {
        NSFrameRect(rect);
    } else {
        NSRectFill(rect);
    }
}

- (void)drawInvertedRectAtRow:(int)row column:(int)col numRows:(int)nrows
                   numColumns:(int)ncols
{
    // TODO: THIS CODE HAS NOT BEEN TESTED!
    CGContextRef cgctx = [[NSGraphicsContext currentContext] graphicsPort];
    CGContextSaveGState(cgctx);
    CGContextSetBlendMode(cgctx, kCGBlendModeDifference);
    CGContextSetRGBFillColor(cgctx, 1.0, 1.0, 1.0, 1.0);

    CGRect rect = { col * cellSize.width, row * cellSize.height,
                    ncols * cellSize.width, nrows * cellSize.height };
    CGContextFillRect(cgctx, rect);

    CGContextRestoreGState(cgctx);
}

@end // MMAtsuiTextView (Drawing)
