//
//  iTermMetalGlue.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 10/8/17.
//

#import "iTermMetalGlue.h"

#import "DebugLogging.h"
#import "iTermColorMap.h"
#import "iTermController.h"
#import "iTermSelection.h"
#import "iTermSmartCursorColor.h"
#import "iTermTextDrawingHelper.h"
#import "NSColor+iTerm.h"
#import "NSImage+iTerm.h"
#import "PTYFontInfo.h"
#import "PTYTextView.h"
#import "VT100Screen.h"

NS_ASSUME_NONNULL_BEGIN

extern void CGContextSetFontSmoothingStyle(CGContextRef, int);
extern int CGContextGetFontSmoothingStyle(CGContextRef);

typedef struct {
    unsigned int isMatch : 1;
    unsigned int inUnderlinedRange : 1;
    unsigned int selected : 1;
    unsigned int foregroundColor : 8;
    unsigned int fgGreen : 8;
    unsigned int fgBlue  : 8;
    unsigned int bold : 1;
    unsigned int faint : 1;
    vector_float4 background;
} iTermTextColorKey;

typedef struct {
    int bgColor;
    int bgGreen;
    int bgBlue;
    ColorMode bgColorMode;
    BOOL selected;
    BOOL isMatch;
} iTermBackgroundColorKey;

static vector_float4 VectorForColor(NSColor *color) {
    return (vector_float4) { color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent };
}

static NSColor *ColorForVector(vector_float4 v) {
    return [NSColor colorWithRed:v.x green:v.y blue:v.z alpha:v.w];
}

#warning TODO: This is copied from drawing helper
static BOOL iTermTextDrawingHelperIsCharacterDrawable(screen_char_t *c,
                                                      BOOL hasStringRepresentation,
                                                      BOOL blinkingItemsVisible,
                                                      BOOL blinkAllowed) {
    const unichar code = c->code;
    if ((code == DWC_RIGHT ||
         code == DWC_SKIP ||
         code == TAB_FILLER) && !c->complexChar) {
        return NO;
    }
    if (blinkingItemsVisible || !(blinkAllowed && c->blink)) {
        // This char is either not blinking or during the "on" cycle of the
        // blink. It should be drawn.

        if (c->complexChar) {
            // TODO: Not all composed/surrogate pair grapheme clusters are drawable
            return hasStringRepresentation;
        } else {
            // Non-complex char
            // TODO: There are other spaces in unicode that should be supported.
            return (code != 0 &&
                    code != '\t' &&
                    !(code >= ITERM2_PRIVATE_BEGIN && code <= ITERM2_PRIVATE_END));

        }
    } else {
        // Chatacter hidden because of blinking.
        return NO;
    }
}


@interface iTermMetalGlue()
// Screen-relative cursor location on last frame
@property (nonatomic) VT100GridCoord oldCursorScreenCoord;
// Used to remember the last time the cursor moved to avoid drawing a blinked-out
// cursor while it's moving.
@property (nonatomic) NSTimeInterval lastTimeCursorMoved;
@end

@interface iTermMetalPerFrameState : NSObject<
    iTermMetalDriverDataSourcePerFrameState,
    iTermSmartCursorColorDelegate> {
    BOOL _havePreviousCharacterAttributes;
    screen_char_t _previousCharacterAttributes;
    vector_float4 _lastUnprocessedColor;
    BOOL _havePreviousForegroundColor;
    vector_float4 _previousForegroundColor;
    NSMutableArray<NSData *> *_lines;
    NSMutableArray<NSIndexSet *> *_selectedIndexes;
    NSMutableDictionary<NSNumber *, NSData *> *_matches;
    iTermColorMap *_colorMap;
    PTYFontInfo *_asciiFont;
    PTYFontInfo *_nonAsciiFont;
    BOOL _useBoldFont;
    BOOL _useItalicFont;
    BOOL _useNonAsciiFont;
    BOOL _reverseVideo;
    BOOL _useBrightBold;
    BOOL _isFrontTextView;
    vector_float4 _unfocusedSelectionColor;
    CGFloat _transparencyAlpha;
    BOOL _transparencyAffectsOnlyDefaultBackgroundColor;
    iTermMetalCursorInfo *_cursorInfo;
    iTermThinStrokesSetting _thinStrokes;
    BOOL _isRetina;
    BOOL _isInKeyWindow;
    BOOL _textViewIsActiveSession;
    BOOL _shouldDrawFilledInCursor;
    VT100GridSize _gridSize;
    VT100GridCoordRange _visibleRange;
    NSInteger _numberOfScrollbackLines;
    BOOL _cursorVisible;
    BOOL _cursorBlinking;
    BOOL _blinkingItemsVisible;
    BOOL _blinkAllowed;
    NSRange _inputMethodMarkedRange;
    NSTimeInterval _timeSinceCursorMoved;

    CGFloat _backgroundImageBlending;
    BOOL _backgroundImageTiled;
    NSImage *_backgroundImage;
}

- (instancetype)initWithTextView:(PTYTextView *)textView
                          screen:(VT100Screen *)screen
                            glue:(iTermMetalGlue *)glue NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@implementation iTermMetalGlue

#pragma mark - iTermMetalDriverDataSource

- (nullable id<iTermMetalDriverDataSourcePerFrameState>)metalDriverWillBeginDrawingFrame {
    if (self.textView.drawingHelper.delegate == nil) {
        return nil;
    }
    return [[iTermMetalPerFrameState alloc] initWithTextView:self.textView screen:self.screen glue:self];
}

@end

@implementation iTermMetalPerFrameState

- (instancetype)initWithTextView:(PTYTextView *)textView
                          screen:(VT100Screen *)screen
                            glue:(iTermMetalGlue *)glue {
    assert([NSThread isMainThread]);
    self = [super init];
    if (self) {
        _havePreviousCharacterAttributes = NO;
        _isFrontTextView = (textView == [[iTermController sharedInstance] frontTextView]);
        _unfocusedSelectionColor = VectorForColor([[_colorMap colorForKey:kColorMapSelection] colorDimmedBy:2.0/3.0
                                                                                           towardsGrayLevel:0.5]);
        _transparencyAlpha = textView.transparencyAlpha;
        _transparencyAffectsOnlyDefaultBackgroundColor = textView.drawingHelper.transparencyAffectsOnlyDefaultBackgroundColor;

        // Copy lines from model. Always use these for consistency. I should also copy the color map
        // and any other data dependencies.
        _lines = [NSMutableArray array];
        _selectedIndexes = [NSMutableArray array];
        _matches = [NSMutableDictionary dictionary];
        _visibleRange = [textView.drawingHelper coordRangeForRect:textView.enclosingScrollView.documentVisibleRect];
        const int width = _visibleRange.end.x - _visibleRange.start.x;
        for (int i = _visibleRange.start.y; i < _visibleRange.end.y; i++) {
            screen_char_t *line = [screen getLineAtIndex:i];
            [_lines addObject:[NSData dataWithBytes:line length:sizeof(screen_char_t) * width]];
            [_selectedIndexes addObject:[textView.selection selectedIndexesOnLine:i]];
            NSData *findMatches = [textView.drawingHelper.delegate drawingHelperMatchesOnLine:i];
            if (findMatches) {
                _matches[@(i - _visibleRange.start.y)] = findMatches;
            }
        }

        _gridSize = VT100GridSizeMake(textView.dataSource.width,
                                      textView.dataSource.height);
        _colorMap = [textView.colorMap copy];
        _asciiFont = textView.primaryFont;
        _nonAsciiFont = textView.secondaryFont;
        _useBoldFont = textView.useBoldFont;
        _useItalicFont = textView.useItalicFont;
        _useNonAsciiFont = textView.useNonAsciiFont;
        _reverseVideo = textView.dataSource.terminal.reverseVideo;
        _useBrightBold = textView.useBrightBold;
        _thinStrokes = textView.thinStrokes;
        _isRetina = textView.drawingHelper.isRetina;
        _isInKeyWindow = [textView isInKeyWindow];
        _textViewIsActiveSession = [textView.delegate textViewIsActiveSession];
        _shouldDrawFilledInCursor = ([textView.delegate textViewShouldDrawFilledInCursor] || textView.keyFocusStolenCount);
        _numberOfScrollbackLines = textView.dataSource.numberOfScrollbackLines;
        _cursorVisible = textView.drawingHelper.cursorVisible;
        _cursorBlinking = textView.isCursorBlinking;
        _blinkAllowed = textView.blinkAllowed;
        _blinkingItemsVisible = textView.drawingHelper.blinkingItemsVisible;
        _inputMethodMarkedRange = textView.drawingHelper.inputMethodMarkedRange;

        VT100GridCoord cursorScreenCoord = VT100GridCoordMake(textView.dataSource.cursorX - 1,
                                                              textView.dataSource.cursorY - 1);
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (!VT100GridCoordEquals(cursorScreenCoord, glue.oldCursorScreenCoord)) {
            glue.lastTimeCursorMoved = now;
        }
        _timeSinceCursorMoved = now - glue.lastTimeCursorMoved;
        glue.oldCursorScreenCoord = cursorScreenCoord;

        iTermSmartCursorColor *smartCursorColor = nil;
        if (textView.drawingHelper.useSmartCursorColor) {
            smartCursorColor = [[iTermSmartCursorColor alloc] init];
            smartCursorColor.delegate = self;
        }
        _cursorInfo = [[iTermMetalCursorInfo alloc] init];
#warning TODO: blinking cursor
        NSInteger lineWithCursor = textView.dataSource.cursorY - 1 + _numberOfScrollbackLines;
        if ([self shouldDrawCursor] &&
            textView.cursorVisible &&
            _visibleRange.start.y <= lineWithCursor &&
            lineWithCursor + 1 < _visibleRange.end.y) {
            const int offset = _visibleRange.start.y - _numberOfScrollbackLines;
            _cursorInfo.cursorVisible = YES;
            _cursorInfo.type = textView.drawingHelper.cursorType;
            _cursorInfo.coord = VT100GridCoordMake(textView.dataSource.cursorX - 1,
                                                   textView.dataSource.cursorY - 1 - offset);
#warning handle frame cursor, text color, smart cursor color, and other fancy cursors of various kinds
            _cursorInfo.cursorColor = [self backgroundColorForCursor];
            if (_cursorInfo.type == CURSOR_BOX) {
                _cursorInfo.shouldDrawText = YES;
                const screen_char_t *line = (screen_char_t *)_lines[_cursorInfo.coord.y].bytes;
                screen_char_t screenChar = line[_cursorInfo.coord.x];
                const BOOL focused = ((_isInKeyWindow && _textViewIsActiveSession) || _shouldDrawFilledInCursor);
                _cursorInfo.textColor = [self fastCursorColorForCharacter:screenChar
                                                           wantBackground:YES
                                                                    muted:NO];
                if (!focused) {
                    _cursorInfo.frameOnly = YES;
                } else if (smartCursorColor) {
                    _cursorInfo.cursorColor = [smartCursorColor backgroundColorForCharacter:screenChar];
                    NSColor *regularTextColor = [NSColor colorWithRed:_cursorInfo.textColor.x
                                                                green:_cursorInfo.textColor.y
                                                                 blue:_cursorInfo.textColor.z
                                                                alpha:_cursorInfo.textColor.w];
                    NSColor *smartTextColor = [smartCursorColor textColorForCharacter:screenChar
                                                                     regularTextColor:regularTextColor
                                                                 smartBackgroundColor:_cursorInfo.cursorColor];
                    CGFloat components[4];
                    [smartTextColor getComponents:components];
                    _cursorInfo.textColor = simd_make_float4(components[0],
                                                             components[1],
                                                             components[2],
                                                             components[3]);
                }
            }
        } else {
            _cursorInfo.cursorVisible = NO;
        }

        _backgroundImageBlending = textView.blend;
        _backgroundImageTiled = textView.delegate.backgroundImageTiled;
        _backgroundImage = [textView.delegate textViewBackgroundImage];
    }
    return self;
}

- (VT100GridSize)gridSize {
    return _gridSize;
}

- (vector_float4)defaultBackgroundColor {
    NSColor *color = [_colorMap colorForKey:kColorMapBackground];
    return simd_make_float4((float)color.redComponent,
                            (float)color.greenComponent,
                            (float)color.blueComponent,
                            1);
}

// Private queue
- (nullable iTermMetalCursorInfo *)metalDriverCursorInfo {
    return _cursorInfo;
}

// Private queue
- (NSImage *)metalBackgroundImageGetBlending:(CGFloat *)blending tiled:(BOOL *)tiled {
    *blending = _backgroundImageBlending;
    *tiled = _backgroundImageTiled;
    return _backgroundImage;
}

// Private queue
- (void)metalGetGlyphKeys:(iTermMetalGlyphKey *)glyphKeys
               attributes:(iTermMetalGlyphAttributes *)attributes
               background:(vector_float4 *)background
                      row:(int)row
                    width:(int)width
           drawableGlyphs:(int *)drawableGlyphsPtr {
    screen_char_t *line = (screen_char_t *)_lines[row].bytes;
    NSIndexSet *selectedIndexes = _selectedIndexes[row];
    NSData *findMatches = _matches[@(row)];
    iTermTextColorKey keys[2];
    iTermTextColorKey *currentColorKey = &keys[0];
    iTermTextColorKey *previousColorKey = &keys[1];
    iTermBackgroundColorKey lastBackgroundKey;

    int lastDrawableGlyph = -1;
    for (int x = 0; x < width; x++) {
        BOOL selected = [selectedIndexes containsIndex:x];
        BOOL findMatch = NO;
        if (findMatches && !selected) {
            findMatch = CheckFindMatchAtIndex(findMatches, x);
        }

        // Background colors
        iTermBackgroundColorKey backgroundKey = {
            .bgColor = line[x].backgroundColor,
            .bgGreen = line[x].bgGreen,
            .bgBlue = line[x].bgBlue,
            .bgColorMode = line[x].backgroundColorMode,
            .selected = selected,
            .isMatch = findMatch,
        };
        if (x > 1 &&
            backgroundKey.bgColor == lastBackgroundKey.bgColor &&
            backgroundKey.bgGreen == lastBackgroundKey.bgGreen &&
            backgroundKey.bgBlue == lastBackgroundKey.bgBlue &&
            backgroundKey.bgColorMode == lastBackgroundKey.bgColorMode &&
            backgroundKey.selected == lastBackgroundKey.selected &&
            backgroundKey.isMatch == lastBackgroundKey.isMatch) {
            background[x] = background[x - 1];
        } else {
            vector_float4 unprocessed = [self unprocessedColorForBackgroundColorKey:&backgroundKey];
            // The unprocessed color is needed for minimum contrast computation for text color.
            background[x] = [_colorMap fastProcessedBackgroundColorForBackgroundColor:unprocessed];
            if (_backgroundImage) {
                // This is kind of ugly but it simplifies things a lot to do it
                // here. The alpha value for background colors should be 1
                // except when there's a background image, in which case the
                // default background color gets a user-defined alpha value.
                const BOOL isDefaultBackgroundColor = (backgroundKey.bgColorMode == ColorModeAlternate &&
                                                       backgroundKey.bgColor == ALTSEM_DEFAULT);
                background[x].w = isDefaultBackgroundColor ? (1 - _backgroundImageBlending) : 1;
            }
        }
        lastBackgroundKey = backgroundKey;
        attributes[x].backgroundColor = background[x];
        attributes[x].backgroundColor.w = 1;

        // Foreground colors
        // Build up a compact key describing all the inputs to a text color
        currentColorKey->isMatch = findMatch;
        currentColorKey->inUnderlinedRange = NO;  // TODO
        currentColorKey->selected = selected;
        currentColorKey->foregroundColor = line[x].foregroundColor;
        currentColorKey->fgGreen = line[x].fgGreen;
        currentColorKey->fgBlue = line[x].fgBlue;
        currentColorKey->bold = line[x].bold;
        currentColorKey->faint = line[x].faint;
        currentColorKey->background = background[x];
        if (x > 0 &&
            currentColorKey->isMatch == previousColorKey->isMatch &&
            currentColorKey->inUnderlinedRange == previousColorKey->inUnderlinedRange &&
            currentColorKey->selected == previousColorKey->selected &&
            currentColorKey->foregroundColor == previousColorKey->foregroundColor &&
            currentColorKey->fgGreen == previousColorKey->fgGreen &&
            currentColorKey->fgBlue == previousColorKey->fgBlue &&
            currentColorKey->bold == previousColorKey->bold &&
            currentColorKey->faint == previousColorKey->faint &&
            simd_equal(currentColorKey->background, previousColorKey->background)) {
            attributes[x].foregroundColor = attributes[x - 1].foregroundColor;
        } else {
            vector_float4 textColor = [self textColorForCharacter:&line[x]
                                                             line:row
                                                  backgroundColor:background[x]
                                                         selected:selected
                                                        findMatch:findMatch
                                                inUnderlinedRange:NO  // TODO
                                                            index:x];
            attributes[x].foregroundColor = textColor;
            attributes[x].foregroundColor.w = 1;
        }

        // Swap current and previous
        iTermTextColorKey *temp = currentColorKey;
        currentColorKey = previousColorKey;
        previousColorKey = temp;

        // Also need to take into account which font will be used (bold, italic, nonascii, etc.) plus
        // box drawing and images. If I want to support subpixel rendering then background color has
        // to be a factor also.
        glyphKeys[x].code = line[x].code;
        glyphKeys[x].isComplex = line[x].complexChar;
        glyphKeys[x].image = line[x].image;
        glyphKeys[x].boxDrawing = NO;
        glyphKeys[x].thinStrokes = [self useThinStrokesWithAttributes:&attributes[x]];

        if (iTermTextDrawingHelperIsCharacterDrawable(&line[x],
                                                      ScreenCharToStr(&line[x]) != nil,
                                                      _blinkingItemsVisible,
                                                      _blinkAllowed)) {
            lastDrawableGlyph = x;
            glyphKeys[x].drawable = YES;
        } else {
            glyphKeys[x].drawable = NO;
        }
    }

    *drawableGlyphsPtr = lastDrawableGlyph + 1;

    // Tweak the text color for the cell that has a box cursor.
    if (_cursorInfo.cursorVisible &&
        _cursorInfo.type == CURSOR_BOX &&
        row == _cursorInfo.coord.y) {
        vector_float4 cursorTextColor;
        if (_reverseVideo) {
            cursorTextColor = VectorForColor([_colorMap colorForKey:kColorMapBackground]);
        } else {
            cursorTextColor = [self colorForCode:ALTSEM_CURSOR
                                           green:0
                                            blue:0
                                       colorMode:ColorModeAlternate
                                            bold:NO
                                           faint:NO
                                    isBackground:NO];
        }
        attributes[_cursorInfo.coord.x].foregroundColor = cursorTextColor.x;
        attributes[_cursorInfo.coord.x].foregroundColor.w = 1;
    }
}

- (BOOL)useThinStrokesWithAttributes:(iTermMetalGlyphAttributes *)attributes {
    switch (_thinStrokes) {
        case iTermThinStrokesSettingAlways:
            return YES;

        case iTermThinStrokesSettingDarkBackgroundsOnly:
            break;

        case iTermThinStrokesSettingNever:
            return NO;

        case iTermThinStrokesSettingRetinaDarkBackgroundsOnly:
            if (!_isRetina) {
                return NO;
            }
            break;

        case iTermThinStrokesSettingRetinaOnly:
            return _isRetina;
    }

    const float backgroundBrightness = SIMDPerceivedBrightness(attributes->backgroundColor);
    const float foregroundBrightness = SIMDPerceivedBrightness(attributes->foregroundColor);
    return backgroundBrightness < foregroundBrightness;
}

- (vector_float4)selectionColorForCurrentFocus {
    if (_isFrontTextView) {
        return VectorForColor([_colorMap processedBackgroundColorForBackgroundColor:[_colorMap colorForKey:kColorMapSelection]]);
    } else {
        return _unfocusedSelectionColor;
    }
}

- (vector_float4)unprocessedColorForBackgroundColorKey:(iTermBackgroundColorKey *)colorKey {
    vector_float4 color = { 0, 0, 0, 0 };
    CGFloat alpha = _transparencyAlpha;
    if (colorKey->selected) {
        color = [self selectionColorForCurrentFocus];
        if (_transparencyAffectsOnlyDefaultBackgroundColor) {
            alpha = 1;
        }
    } else if (colorKey->isMatch) {
        color = (vector_float4){ 1, 1, 0, 1 };
    } else {
        const BOOL defaultBackground = (colorKey->bgColor == ALTSEM_DEFAULT &&
                                        colorKey->bgColorMode == ColorModeAlternate);
        // When set in preferences, applies alpha only to the defaultBackground
        // color, useful for keeping Powerline segments opacity(background)
        // consistent with their seperator glyphs opacity(foreground).
        if (_transparencyAffectsOnlyDefaultBackgroundColor && !defaultBackground) {
            alpha = 1;
        }
        if (_reverseVideo && defaultBackground) {
            // Reverse video is only applied to default background-
            // color chars.
            color = [self colorForCode:ALTSEM_DEFAULT
                                 green:0
                                  blue:0
                             colorMode:ColorModeAlternate
                                  bold:NO
                                 faint:NO
                          isBackground:NO];
        } else {
            // Use the regular background color.
            color = [self colorForCode:colorKey->bgColor
                                 green:colorKey->bgGreen
                                  blue:colorKey->bgBlue
                             colorMode:colorKey->bgColorMode
                                  bold:NO
                                 faint:NO
                          isBackground:YES];
        }

//        if (defaultBackground && _hasBackgroundImage) {
//            alpha = 1 - _blend;
//        }
    }
    color.w = alpha;
    return color;
}

#warning Remember to add support for blinking text.

- (vector_float4)colorForCode:(int)theIndex
                        green:(int)green
                         blue:(int)blue
                    colorMode:(ColorMode)theMode
                         bold:(BOOL)isBold
                        faint:(BOOL)isFaint
                 isBackground:(BOOL)isBackground {
    iTermColorMapKey key = [self colorMapKeyForCode:theIndex
                                              green:green
                                               blue:blue
                                          colorMode:theMode
                                               bold:isBold
                                       isBackground:isBackground];
    if (isBackground) {
        return VectorForColor([_colorMap colorForKey:key]);
    } else {
        vector_float4 color = VectorForColor([_colorMap colorForKey:key]);
        if (isFaint) {
            color.w = 0.5;
        }
        return color;
    }
}

- (iTermColorMapKey)colorMapKeyForCode:(int)theIndex
                                 green:(int)green
                                  blue:(int)blue
                             colorMode:(ColorMode)theMode
                                  bold:(BOOL)isBold
                          isBackground:(BOOL)isBackground {
    BOOL isBackgroundForDefault = isBackground;
    switch (theMode) {
        case ColorModeAlternate:
            switch (theIndex) {
                case ALTSEM_SELECTED:
                    if (isBackground) {
                        return kColorMapSelection;
                    } else {
                        return kColorMapSelectedText;
                    }
                case ALTSEM_CURSOR:
                    if (isBackground) {
                        return kColorMapCursor;
                    } else {
                        return kColorMapCursorText;
                    }
                case ALTSEM_REVERSED_DEFAULT:
                    isBackgroundForDefault = !isBackgroundForDefault;
                    // Fall through.
                case ALTSEM_DEFAULT:
                    if (isBackgroundForDefault) {
                        return kColorMapBackground;
                    } else {
                        if (isBold && _useBrightBold) {
                            return kColorMapBold;
                        } else {
                            return kColorMapForeground;
                        }
                    }
            }
            break;
        case ColorMode24bit:
            return [iTermColorMap keyFor8bitRed:theIndex green:green blue:blue];
        case ColorModeNormal:
            // Render bold text as bright. The spec (ECMA-48) describes the intense
            // display setting (esc[1m) as "bold or bright". We make it a
            // preference.
            if (isBold &&
                _useBrightBold &&
                (theIndex < 8) &&
                !isBackground) { // Only colors 0-7 can be made "bright".
                theIndex |= 8;  // set "bright" bit.
            }
            return kColorMap8bitBase + (theIndex & 0xff);

        case ColorModeInvalid:
            return kColorMapInvalid;
    }
    NSAssert(ok, @"Bogus color mode %d", (int)theMode);
    return kColorMapInvalid;
}

- (NSDictionary<NSNumber *,NSImage *> *)metalImagesForGlyphKey:(iTermMetalGlyphKey *)glyphKey
                                                          size:(CGSize)size
                                                         scale:(CGFloat)scale {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();

    BOOL fakeBold = NO;
    BOOL fakeItalic = NO;
    const BOOL isAscii = !glyphKey->isComplex && (glyphKey->code < 128);
    PTYFontInfo *fontInfo = [PTYFontInfo fontForAsciiCharacter:isAscii
                                                     asciiFont:_asciiFont
                                                  nonAsciiFont:_nonAsciiFont
                                                   useBoldFont:_useBoldFont
                                                 useItalicFont:_useItalicFont
                                              usesNonAsciiFont:_useNonAsciiFont
                                                    renderBold:&fakeBold
                                                  renderItalic:&fakeItalic];
    NSFont *font = fontInfo.font;
    assert(font);

    NSImage *image;
    CGRect rect = [self drawGlyphKey:glyphKey
                                font:font
                                size:size
                              offset:CGPointZero
                      baselineOffset:fontInfo.baselineOffset
                               scale:scale
                      useThinStrokes:glyphKey->thinStrokes
                   colorSpace:colorSpace
                               image:&image];
    CGColorSpaceRelease(colorSpace);

    if (image == nil) {
        return nil;
    }

    NSMutableDictionary<NSNumber *, NSImage *> *result = [NSMutableDictionary dictionary];
    result[@4] = image;

    // Check the eight cells surrounding and see if the glyph spills into them and output additional images if so.
    // The key identifies which neighboring cell.
    // 0 1 2
    // 3 4 5
    // 6 7 8
    int i = 0;
    for (int y = 0; y < 3; y++) {
        for (int x = 0; x < 3; x++) {
            if (i == 4) {
                i++;
                continue;
            }
            CGRect quadrant = CGRectMake((x - 1) * size.width, (y - 1) * size.height, size.width, size.height);
            if (CGRectIntersectsRect(quadrant, rect)) {
                image = nil;
                [self drawGlyphKey:glyphKey
                              font:font
                              size:size
                            offset:CGPointMake(-quadrant.origin.x, -quadrant.origin.y)
                    baselineOffset:fontInfo.baselineOffset
                             scale:scale
                    useThinStrokes:glyphKey->thinStrokes
                        colorSpace:colorSpace
                             image:&image];
                if (image) {
                    result[@(i)] = image;
                }
            }
            i++;
        }
    }
    return result;
}

- (CGRect)drawGlyphKey:(iTermMetalGlyphKey *)glyphKey
                  font:(NSFont *)font
                  size:(CGSize)size
                offset:(CGPoint)offset
        baselineOffset:(CGFloat)baselineOffset
                 scale:(CGFloat)scale
        useThinStrokes:(BOOL)useThinStrokes
            colorSpace:(CGColorSpaceRef)colorSpace
                 image:(NSImage **)imagePtr {
    CGContextRef ctx = CGBitmapContextCreate(NULL,
                                             size.width,
                                             size.height,
                                             8,
                                             size.width * 4,
                                             colorSpace,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);

    CGRect rect = [self drawStringUsingCoreText:CharToStr(glyphKey->code, glyphKey->isComplex)
                                           font:font
                                           size:size
                                         offset:offset
                                 baselineOffset:baselineOffset
                                          scale:scale
                                 useThinStrokes:glyphKey->thinStrokes
                                        context:ctx];

    CGImageRef imageRef = CGBitmapContextCreateImage(ctx);

    *imagePtr = [[NSImage alloc] initWithCGImage:imageRef size:size];

    return rect;
}

#pragma mark - Letter Drawing

- (CGRect)drawStringUsingCoreText:(NSString *)string
                             font:(NSFont *)font
                             size:(CGSize)size
                           offset:(CGPoint)offset
                   baselineOffset:(CGFloat)baselineOffset
                            scale:(CGFloat)scale
                   useThinStrokes:(BOOL)useThinStrokes
                          context:(CGContextRef)cgContext {
    // Fill the background with white.
    CGContextSetRGBFillColor(cgContext, 1, 1, 1, 1);
    CGContextFillRect(cgContext, CGRectMake(0, 0, size.width, size.height));

    DLog(@"Draw %@ of size %@", string, NSStringFromSize(size));
    if (string.length == 0) {
        return CGRectZero;
    }

    static NSMutableParagraphStyle *paragraphStyle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        paragraphStyle.lineBreakMode = NSLineBreakByClipping;
        paragraphStyle.tabStops = @[];
        paragraphStyle.baseWritingDirection = NSWritingDirectionLeftToRight;
    });

    // TODO: Figure out how to support ligatures.
    NSDictionary *attributes = @{ (NSString *)kCTLigatureAttributeName: @0,
                                  (NSString *)kCTForegroundColorAttributeName: (id)[[NSColor blackColor] CGColor],
                                  NSFontAttributeName: font,
                                  NSParagraphStyleAttributeName: paragraphStyle };
    NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    CTLineRef lineRef;
    lineRef = CTLineCreateWithAttributedString((CFAttributedStringRef)attributedString);
    CFArrayRef runs = CTLineGetGlyphRuns(lineRef);

    CGContextSetShouldAntialias(cgContext, YES);
    CGContextSetFillColorWithColor(cgContext, [[NSColor blackColor] CGColor]);
    CGContextSetStrokeColorWithColor(cgContext, [[NSColor blackColor] CGColor]);

    CGFloat c = 0.0;
#warning Suport fake bold and fake italic
    const BOOL fakeItalic = NO;
    if (fakeItalic) {
        c = 0.2;
    }

    if (useThinStrokes) {
        CGContextSetShouldSmoothFonts(cgContext, YES);
        // This seems to be available at least on 10.8 and later. The only reference to it is in
        // WebKit. This causes text to render just a little lighter, which looks nicer.
        CGContextSetFontSmoothingStyle(cgContext, 16);
    }

    const CGFloat ty = offset.y - baselineOffset * scale;
    CGAffineTransform textMatrix = CGAffineTransformMake(scale, 0.0,
                                                         c, scale,
                                                         offset.x, ty);
    CGContextSetTextMatrix(cgContext, textMatrix);

    for (CFIndex j = 0; j < CFArrayGetCount(runs); j++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, j);
        size_t length = CTRunGetGlyphCount(run);
        const CGGlyph *buffer = CTRunGetGlyphsPtr(run);
        if (!buffer) {
            NSMutableData *tempBuffer =
                [[NSMutableData alloc] initWithLength:sizeof(CGGlyph) * length];
            CTRunGetGlyphs(run, CFRangeMake(0, length), (CGGlyph *)tempBuffer.mutableBytes);
            buffer = tempBuffer.mutableBytes;
        }

        NSMutableData *positionsBuffer =
            [[NSMutableData alloc] initWithLength:sizeof(CGPoint) * length];
        CTRunGetPositions(run, CFRangeMake(0, length), (CGPoint *)positionsBuffer.mutableBytes);
        CGPoint *positions = positionsBuffer.mutableBytes;

        const CFIndex *glyphIndexToCharacterIndex = CTRunGetStringIndicesPtr(run);
        if (!glyphIndexToCharacterIndex) {
            NSMutableData *tempBuffer =
                [[NSMutableData alloc] initWithLength:sizeof(CFIndex) * length];
            CTRunGetStringIndices(run, CFRangeMake(0, length), (CFIndex *)tempBuffer.mutableBytes);
            glyphIndexToCharacterIndex = (CFIndex *)tempBuffer.mutableBytes;
        }

        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, cgContext);
    }

    CGRect frame = CTLineGetImageBounds(lineRef, cgContext);
    frame.origin.y += baselineOffset;
    frame.origin.x *= scale;
    frame.origin.y *= scale;
    frame.size.width *= scale;
    frame.size.height *= scale;
    // This is set to cut off subpixels that spill into neighbors as an optimization.
    CGPoint min = CGPointMake(ceil(CGRectGetMinX(frame)),
                              ceil(CGRectGetMinY(frame)));
    CGPoint max = CGPointMake(floor(CGRectGetMaxX(frame)),
                              floor(CGRectGetMaxY(frame)));
    frame = CGRectMake(min.x, min.y, max.x - min.x, max.y - min.y);

    CFRelease(lineRef);

    return frame;
}

#pragma mark - Color

- (vector_float4)textColorForCharacter:(screen_char_t *)c
                                  line:(int)line
                       backgroundColor:(vector_float4)backgroundColor
                              selected:(BOOL)selected
                             findMatch:(BOOL)findMatch
                     inUnderlinedRange:(BOOL)inUnderlinedRange
                                 index:(int)index {
    vector_float4 rawColor = { 0, 0, 0, 0 };
    BOOL isMatch = NO;
    iTermColorMap *colorMap = _colorMap;
    const BOOL needsProcessing = (colorMap.minimumContrast > 0.001 ||
                                  colorMap.dimmingAmount > 0.001 ||
                                  colorMap.mutingAmount > 0.001 ||
                                  c->faint);  // faint implies alpha<1 and is faster than getting the alpha component


    if (isMatch) {
        // Black-on-yellow search result.
        rawColor = (vector_float4){ 0, 0, 0, 1 };
        _havePreviousCharacterAttributes = NO;
    } else if (inUnderlinedRange) {
        // Blue link text.
        rawColor = VectorForColor([_colorMap colorForKey:kColorMapLink]);
        _havePreviousCharacterAttributes = NO;
    } else if (selected) {
        // Selected text.
        rawColor = VectorForColor([colorMap colorForKey:kColorMapSelectedText]);
        _havePreviousCharacterAttributes = NO;
    } else if (_reverseVideo &&
               ((c->foregroundColor == ALTSEM_DEFAULT && c->foregroundColorMode == ColorModeAlternate) ||
                (c->foregroundColor == ALTSEM_CURSOR && c->foregroundColorMode == ColorModeAlternate))) {
           // Reverse video is on. Either is cursor or has default foreground color. Use
           // background color.
           rawColor = VectorForColor([colorMap colorForKey:kColorMapBackground]);
           _havePreviousCharacterAttributes = NO;
    } else if (!_havePreviousCharacterAttributes ||
               c->foregroundColor != _previousCharacterAttributes.foregroundColor ||
               c->fgGreen != _previousCharacterAttributes.fgGreen ||
               c->fgBlue != _previousCharacterAttributes.fgBlue ||
               c->foregroundColorMode != _previousCharacterAttributes.foregroundColorMode ||
               c->bold != _previousCharacterAttributes.bold ||
               c->faint != _previousCharacterAttributes.faint ||
               !_havePreviousForegroundColor) {
        // "Normal" case for uncached text color. Recompute the unprocessed color from the character.
        _previousCharacterAttributes = *c;
        _havePreviousCharacterAttributes = YES;
        rawColor = [self colorForCode:c->foregroundColor
                                green:c->fgGreen
                                 blue:c->fgBlue
                            colorMode:c->foregroundColorMode
                                 bold:c->bold
                                faint:c->faint
                         isBackground:NO];
    } else {
        // Foreground attributes are just like the last character. There is a cached foreground color.
        if (needsProcessing) {
            // Process the text color for the current background color, which has changed since
            // the last cell.
            rawColor = _lastUnprocessedColor;
        } else {
            // Text color is unchanged. Either it's independent of the background color or the
            // background color has not changed.
            return _previousForegroundColor;
        }
    }

    _lastUnprocessedColor = rawColor;

    vector_float4 result;
    if (needsProcessing) {
        result = VectorForColor([_colorMap processedTextColorForTextColor:ColorForVector(rawColor)
                                                      overBackgroundColor:ColorForVector(backgroundColor)]);
    } else {
        result = rawColor;
    }
    _previousForegroundColor = result;
    _havePreviousForegroundColor = YES;
    return result;
}

- (NSColor *)backgroundColorForCursor {
    NSColor *color;
    if (_reverseVideo) {
        color = [[_colorMap colorForKey:kColorMapCursorText] colorWithAlphaComponent:1.0];
    } else {
        color = [[_colorMap colorForKey:kColorMapCursor] colorWithAlphaComponent:1.0];
    }
    return [_colorMap colorByDimmingTextColor:color];
}

#warning TODO: Lots of code was copied from PTYTextView. Make it shared.

#pragma mark - iTermSmartCursorColorDelegate

- (iTermCursorNeighbors)cursorNeighbors {
    iTermCursorNeighbors neighbors;
    memset(&neighbors, 0, sizeof(neighbors));
    NSArray *coords = @[ @[ @0,    @(-1) ],     // Above
                         @[ @(-1), @0    ],     // Left
                         @[ @1,    @0    ],     // Right
                         @[ @0,    @1    ] ];   // Below
    int prevY = -2;
    const screen_char_t *theLine = nil;

    for (NSArray *tuple in coords) {
        int dx = [tuple[0] intValue];
        int dy = [tuple[1] intValue];
        int x = _cursorInfo.coord.x + dx;
        int y = _cursorInfo.coord.y + dy + _numberOfScrollbackLines;

        if (y != prevY) {
            if (y >= _visibleRange.start.y && y < _visibleRange.end.y) {
                theLine = (const screen_char_t *)_lines[y - _visibleRange.start.y].bytes;
            } else {
                theLine = nil;
            }
        }
        prevY = y;

        int xi = dx + 1;
        int yi = dy + 1;
        if (theLine && x >= 0 && x < _gridSize.width) {
            neighbors.chars[yi][xi] = theLine[x];
            neighbors.valid[yi][xi] = YES;
        }

    }
    return neighbors;
}

// TODO: This is copypasta
- (vector_float4)fastCursorColorForCharacter:(screen_char_t)screenChar
                              wantBackground:(BOOL)wantBackgroundColor
                                       muted:(BOOL)muted {
    BOOL isBackground = wantBackgroundColor;

    if (_reverseVideo) {
        if (wantBackgroundColor &&
            screenChar.backgroundColorMode == ColorModeAlternate &&
            screenChar.backgroundColor == ALTSEM_DEFAULT) {
            isBackground = NO;
        } else if (!wantBackgroundColor &&
                   screenChar.foregroundColorMode == ColorModeAlternate &&
                   screenChar.foregroundColor == ALTSEM_DEFAULT) {
            isBackground = YES;
        }
    }
    vector_float4 color;
    if (wantBackgroundColor) {
        color = [self colorForCode:screenChar.backgroundColor
                             green:screenChar.bgGreen
                              blue:screenChar.bgBlue
                         colorMode:screenChar.backgroundColorMode
                              bold:screenChar.bold
                             faint:screenChar.faint
                      isBackground:isBackground];
    } else {
        color = [self colorForCode:screenChar.foregroundColor
                             green:screenChar.fgGreen
                              blue:screenChar.fgBlue
                         colorMode:screenChar.foregroundColorMode
                              bold:screenChar.bold
                             faint:screenChar.faint
                      isBackground:isBackground];
    }
    if (muted) {
        color = [_colorMap fastColorByMutingColor:color];
    }
    return color;
}

- (NSColor *)cursorColorForCharacter:(screen_char_t)screenChar
                      wantBackground:(BOOL)wantBackgroundColor
                               muted:(BOOL)muted {
    vector_float4 v = [self fastCursorColorForCharacter:screenChar wantBackground:wantBackgroundColor muted:muted];
    return [NSColor colorWithRed:v.x green:v.y blue:v.z alpha:v.w];
}

- (NSColor *)cursorColorByDimmingSmartColor:(NSColor *)color {
    return [_colorMap colorByDimmingTextColor:color];
}

- (NSColor *)cursorWhiteColor {
    NSColor *whiteColor = [NSColor colorWithCalibratedRed:1
                                                    green:1
                                                     blue:1
                                                    alpha:1];
    return [_colorMap colorByDimmingTextColor:whiteColor];
}

- (NSColor *)cursorBlackColor {
    NSColor *blackColor = [NSColor colorWithCalibratedRed:0
                                                    green:0
                                                     blue:0
                                                    alpha:1];
    return [_colorMap colorByDimmingTextColor:blackColor];
}

#pragma mark - Cursor Logic

#warning TODO: This is copypasta

- (BOOL)shouldDrawCursor {
    BOOL shouldShowCursor = [self shouldShowCursor];

    // Draw the regular cursor only if there's not an IME open as it draws its
    // own cursor. Also, it must be not blinked-out, and it must be within the expected bounds of
    // the screen (which is just a sanity check, really).
    BOOL result = (![self hasMarkedText] &&
                   _cursorVisible &&
                   shouldShowCursor);
    DLog(@"shouldDrawCursor: hasMarkedText=%d, cursorVisible=%d, showCursor=%d, result=%@",
         (int)[self hasMarkedText], (int)_cursorVisible, (int)shouldShowCursor, @(result));
    return result;
}

- (BOOL)shouldShowCursor {
    if (_cursorBlinking &&
        _isInKeyWindow &&
        _textViewIsActiveSession &&
        _timeSinceCursorMoved > 0.5) {
        // Allow the cursor to blink if it is configured, the window is key, this session is active
        // in the tab, and the cursor has not moved for half a second.
        return _blinkingItemsVisible;
    } else {
        return YES;
    }
}

- (BOOL)hasMarkedText {
    return _inputMethodMarkedRange.length > 0;
}


@end

NS_ASSUME_NONNULL_END