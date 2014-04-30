/*
 * cocos2d for iPhone: http://www.cocos2d-iphone.org
 *
 * Copyright (c) 2009 Jason Booth
 * Copyright (c) 2013-2014 Cocos2D Authors
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 */

#import "CCRenderTexture.h"
#import "CCDirector.h"
#import "ccMacros.h"
#import "CCShader.h"
#import "CCConfiguration.h"
#import "Support/ccUtils.h"
#import "Support/CCFileUtils.h"
#import "Support/CGPointExtension.h"

#import "CCTexture_Private.h"
#import "CCDirector_Private.h"
#import "CCNode_Private.h"
#import "CCRenderer_private.h"

#if __CC_PLATFORM_MAC
#import <ApplicationServices/ApplicationServices.h>
#endif


@interface CCRenderTextureSprite : CCSprite @end
@implementation CCRenderTextureSprite

-(CCRenderState *)renderState
{
	if(_renderState == nil){
		if(_shaderUniforms.count > 1){
			_renderState = [[CCRenderState alloc] initWithBlendMode:_blendMode shader:_shader shaderUniforms:_shaderUniforms];
		} else {
			// Creating a regular, cached render state here would be mildly bad.
			// The state would prevent the render texture from being released until the cache is flushed.
			NSDictionary *uniforms = @{CCShaderUniformMainTexture:(_texture ?: [CCTexture none])};
			_renderState = [[CCRenderState alloc] initWithBlendMode:_blendMode shader:_shader shaderUniforms:uniforms];
		}
	}
	
	return _renderState;
}

@end


@implementation CCRenderTexture {
	CGSize _size;
	GLenum _pixelFormat;
	GLuint _depthStencilFormat;
	
	CCRenderer *_renderer;
	BOOL _privateRenderer;

	GLuint _FBO;
	GLuint _depthRenderBufffer;
	GLKVector4 _clearColor;
	
	GLKVector4 _oldViewport;
	GLint _oldFBO;
	NSDictionary *_oldGlobalUniforms;
}

@dynamic texture;

+(id)renderTextureWithWidth:(int)w height:(int)h pixelFormat:(CCTexturePixelFormat) format depthStencilFormat:(GLuint)depthStencilFormat
{
  return [[self alloc] initWithWidth:w height:h pixelFormat:format depthStencilFormat:depthStencilFormat];
}

// issue #994
+(id)renderTextureWithWidth:(int)w height:(int)h pixelFormat:(CCTexturePixelFormat)format
{
	return [[self alloc] initWithWidth:w height:h pixelFormat:format];
}

+(id)renderTextureWithWidth:(int)w height:(int)h
{
	return [[self alloc] initWithWidth:w height:h pixelFormat:CCTexturePixelFormat_RGBA8888 depthStencilFormat:0];
}

-(id)initWithWidth:(int)w height:(int)h
{
	return [self initWithWidth:w height:h pixelFormat:CCTexturePixelFormat_RGBA8888];
}

- (id)initWithWidth:(int)w height:(int)h pixelFormat:(CCTexturePixelFormat)format
{
  return [self initWithWidth:w height:h pixelFormat:format depthStencilFormat:0];
}

-(id)initWithWidth:(int)width height:(int)height pixelFormat:(CCTexturePixelFormat) format depthStencilFormat:(GLuint)depthStencilFormat
{
	if((self = [super init])){
		NSAssert(format != CCTexturePixelFormat_A8, @"only RGB and RGBA formats are valid for a render texture");

		CCDirector *director = [CCDirector sharedDirector];

		// XXX multithread
		if( [director runningThread] != [NSThread currentThread] )
			CCLOGWARN(@"cocos2d: WARNING. CCRenderTexture is running on its own thread. Make sure that an OpenGL context is being used on this thread!");

		_contentScale = [CCDirector sharedDirector].contentScaleFactor;
		_size = CGSizeMake(width, height);
		_pixelFormat = format;
		_depthStencilFormat = depthStencilFormat;

		// Flip the projection matrix on the y-axis since Cocos2D uses upside down textures.
		_projection = GLKMatrix4MakeOrtho(0.0f, width, height, 0.0f, -1024.0f, 1024.0f);
		
		_sprite = [CCRenderTextureSprite spriteWithTexture:[CCTexture none]];

		// Diabled by default.
		_autoDraw = NO;
		
		// add sprite for backward compatibility
		[self addChild:_sprite];
	}
	return self;
}

-(void)create
{
	glPushGroupMarkerEXT(0, "CCRenderTexture: Create");
	
	int pixelW = _size.width*_contentScale;
	int pixelH = _size.height*_contentScale;

	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &_oldFBO);

	// textures must be power of two
	NSUInteger powW;
	NSUInteger powH;

	if( [[CCConfiguration sharedConfiguration] supportsNPOT] ) {
		powW = pixelW;
		powH = pixelH;
	} else {
		powW = CCNextPOT(pixelW);
		powH = CCNextPOT(pixelH);
	}

	void *data = calloc(powW*powH, 4);

	CCTexture *texture = [[CCTexture alloc] initWithData:data pixelFormat:_pixelFormat pixelsWide:powW pixelsHigh:powH contentSizeInPixels:CGSizeMake(pixelW, pixelH) contentScale:_contentScale];
	self.texture = texture;
	
	free(data);

	GLint oldRBO;
	glGetIntegerv(GL_RENDERBUFFER_BINDING, &oldRBO);

	// generate FBO
	glGenFramebuffers(1, &_FBO);
	glBindFramebuffer(GL_FRAMEBUFFER, _FBO);

	// associate texture with FBO
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, self.texture.name, 0);

	if(_depthStencilFormat){
		//create and attach depth buffer
		glGenRenderbuffers(1, &_depthRenderBufffer);
		glBindRenderbuffer(GL_RENDERBUFFER, _depthRenderBufffer);
		glRenderbufferStorage(GL_RENDERBUFFER, _depthStencilFormat, (GLsizei)powW, (GLsizei)powH);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, _depthRenderBufffer);

		// if depth format is the one with stencil part, bind same render buffer as stencil attachment
		if(_depthStencilFormat == GL_DEPTH24_STENCIL8){
			glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, _depthRenderBufffer);
		}
	}

	// check if it worked (probably worth doing :) )
	NSAssert( glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, @"Could not attach texture to framebuffer");

	[self.texture setAliasTexParameters];
	
	glBindRenderbuffer(GL_RENDERBUFFER, oldRBO);
	glBindFramebuffer(GL_FRAMEBUFFER, _oldFBO);
	
	CC_CHECK_GL_ERROR_DEBUG();
	glPopGroupMarkerEXT();
	
	CGRect rect = CGRectMake(0, 0, _size.width, _size.height);
	_sprite.texture = self.texture;
	[_sprite setTextureRect:rect];
}

-(void)setContentScale:(float)contentScale
{
	if(_contentScale != contentScale){
		_contentScale = contentScale;
		
		[self destroy];
		self.texture = nil;
	}
}

-(void)destroy
{
	glDeleteFramebuffers(1, &_FBO);
	_FBO = 0;
	
	if(_depthRenderBufffer){
		glDeleteRenderbuffers(1, &_depthRenderBufffer);
		_depthRenderBufffer = 0;
	}
}

-(void)dealloc
{
	[self destroy];
}

-(CCTexture *)texture
{
	if(super.texture == nil){
		[self create];
	}
	
	return super.texture;
}

-(GLuint)fbo
{
	if(super.texture == nil){
		[self create];
	}
	
	return _FBO;
}

-(void)begin
{
	_renderer = [CCRenderer currentRenderer];
	
	if(_renderer == nil){
		_renderer = [[CCRenderer alloc] init];
		
		NSMutableDictionary *uniforms = [[CCDirector sharedDirector].globalShaderUniforms mutableCopy];
		uniforms[CCShaderUniformProjection] = [NSValue valueWithGLKMatrix4:_projection];
		_renderer.globalShaderUniforms = uniforms;
		
		[CCRenderer bindRenderer:_renderer];
		_privateRenderer = YES;
	} else {
		_oldGlobalUniforms = _renderer.globalShaderUniforms;
		
		NSMutableDictionary *uniforms = [_oldGlobalUniforms mutableCopy];
		uniforms[CCShaderUniformProjection] = [NSValue valueWithGLKMatrix4:_projection];
		_renderer.globalShaderUniforms = uniforms;
	}
	
	CGSize pixelSize = self.texture.contentSizeInPixels;
	GLuint fbo = [self fbo];
	
	[_renderer enqueueBlock:^{
		glGetFloatv(GL_VIEWPORT, _oldViewport.v);
		glViewport(0, 0, pixelSize.width, pixelSize.height );
		
		glGetIntegerv(GL_FRAMEBUFFER_BINDING, &_oldFBO);
		glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	} globalSortOrder:0 debugLabel:@"CCRenderTexture: Bind FBO" threadSafe:NO];
	
	[_renderer pushGroup];
}

-(void)beginWithClear:(float)r g:(float)g b:(float)b a:(float)a depth:(float)depthValue stencil:(int)stencilValue flags:(GLbitfield)flags
{
	[self begin];
	[_renderer enqueueClear:flags color:GLKVector4Make(r, g, b, a) depth:depthValue stencil:stencilValue globalSortOrder:NSIntegerMin];
}

-(void)beginWithClear:(float)r g:(float)g b:(float)b a:(float)a
{
	[self beginWithClear:r g:g b:b a:a depth:0 stencil:0 flags:GL_COLOR_BUFFER_BIT];
}

-(void)beginWithClear:(float)r g:(float)g b:(float)b a:(float)a depth:(float)depthValue
{
	[self beginWithClear:r g:g b:b a:a depth:depthValue stencil:0 flags:GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT];
}
-(void)beginWithClear:(float)r g:(float)g b:(float)b a:(float)a depth:(float)depthValue stencil:(int)stencilValue
{
	[self beginWithClear:r g:g b:b a:a depth:depthValue stencil:stencilValue flags:GL_COLOR_BUFFER_BIT|GL_DEPTH_BUFFER_BIT|GL_STENCIL_BUFFER_BIT];
}

-(void)end
{
	[_renderer popGroup:0];
	
	[_renderer enqueueBlock:^{
		glBindFramebuffer(GL_FRAMEBUFFER, _oldFBO);
		glViewport(_oldViewport.v[0], _oldViewport.v[1], _oldViewport.v[2], _oldViewport.v[3]);
	} globalSortOrder:0 debugLabel:@"CCRenderTexture: Restore FBO" threadSafe:NO];
	
	if(_privateRenderer){
		[_renderer flush];
		[CCRenderer bindRenderer:nil];
		_privateRenderer = NO;
	} else {
		_renderer.globalShaderUniforms = _oldGlobalUniforms;
	}
	
	_renderer = nil;
}

-(void)clear:(float)r g:(float)g b:(float)b a:(float)a
{
	[self beginWithClear:r g:g b:b a:a];
	[self end];
}

- (void)clearDepth:(float)depthValue
{
	[self begin];
		[_renderer enqueueClear:GL_DEPTH_BUFFER_BIT color:GLKVector4Make(0, 0, 0, 0) depth:depthValue stencil:0 globalSortOrder:NSIntegerMin];
	[self end];
}

- (void)clearStencil:(int)stencilValue
{
	[self begin];
		[_renderer enqueueClear:GL_DEPTH_BUFFER_BIT color:GLKVector4Make(0, 0, 0, 0) depth:0.0 stencil:stencilValue globalSortOrder:NSIntegerMin];
	[self end];
}

#pragma mark RenderTexture - "auto" update

- (void)visit:(CCRenderer *)renderer parentTransform:(const GLKMatrix4 *)parentTransform
{
	// override visit.
	// Don't call visit on its children
	if(!_visible) return;
	
	if(_autoDraw){
		[self begin];
		NSAssert(_renderer == renderer, @"CCRenderTexture error!");
		
		[_renderer enqueueClear:_clearFlags color:_clearColor depth:_clearDepth stencil:_clearStencil globalSortOrder:NSIntegerMin];
		
		//! make sure all children are drawn
		[self sortAllChildren];
		
		for(CCNode *child in _children){
			if( child != _sprite) [child visit:renderer parentTransform:&_projection];
		}
		
		[self end];
	}
	
	GLKMatrix4 transform = [self transform:parentTransform];
	[_sprite visit:renderer parentTransform:&transform];
	
	_orderOfArrival = 0;
}

#pragma mark RenderTexture - Save Image

-(CGImageRef) newCGImage
{
	NSAssert(_pixelFormat == CCTexturePixelFormat_RGBA8888,@"only RGBA8888 can be saved as image");
	
	CGSize s = [self.texture contentSizeInPixels];
	int tx = s.width;
	int ty = s.height;
	
	int bitsPerComponent = 8;
	int bitsPerPixel = 4 * 8;
	int bytesPerPixel = bitsPerPixel / 8;
	int bytesPerRow = bytesPerPixel * tx;
	NSInteger myDataLength = bytesPerRow * ty;
	
	GLubyte *buffer	= calloc(myDataLength,1);
	GLubyte *pixels	= calloc(myDataLength,1);
	
	
	if( ! (buffer && pixels) ) {
		CCLOG(@"cocos2d: CCRenderTexture#getCGImageFromBuffer: not enough memory");
		free(buffer);
		free(pixels);
		return nil;
	}
	
	[self begin];
	glReadPixels(0,0,tx,ty,GL_RGBA,GL_UNSIGNED_BYTE, buffer);
	[self end];
	
	// make data provider with data.
	
	CGBitmapInfo bitmapInfo	= kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault;
	CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, buffer, myDataLength, NULL);
	CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
	CGImageRef iref	= CGImageCreate(tx, ty,
									bitsPerComponent, bitsPerPixel, bytesPerRow,
									colorSpaceRef, bitmapInfo, provider,
									NULL, false,
									kCGRenderingIntentDefault);
	
	CGContextRef context = CGBitmapContextCreate(pixels, tx,
												 ty, CGImageGetBitsPerComponent(iref),
												 CGImageGetBytesPerRow(iref), CGImageGetColorSpace(iref),
												 bitmapInfo);
	
	// vertically flipped
	if( YES ) {
		CGContextTranslateCTM(context, 0.0f, ty);
		CGContextScaleCTM(context, 1.0f, -1.0f);
	}
	
	CGContextDrawImage(context, CGRectMake(0.0f, 0.0f, tx, ty), iref);
	CGImageRef image = CGBitmapContextCreateImage(context);
	
	CGContextRelease(context);
	CGImageRelease(iref);
	CGColorSpaceRelease(colorSpaceRef);
	CGDataProviderRelease(provider);
	
	free(pixels);
	free(buffer);
	
	return image;
}

-(BOOL) saveToFile:(NSString*)name
{
	return [self saveToFile:name format:CCRenderTextureImageFormatJPEG];
}

-(BOOL)saveToFile:(NSString*)fileName format:(CCRenderTextureImageFormat)format
{
	BOOL success;
	
	NSString *fullPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:fileName];
	
	CGImageRef imageRef = [self newCGImage];

	if( ! imageRef ) {
		CCLOG(@"cocos2d: Error: Cannot create CGImage ref from texture");
		return NO;
	}
	
#if __CC_PLATFORM_IOS
	CGFloat scale = [CCDirector sharedDirector].contentScaleFactor;
	UIImage* image	= [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
	NSData *imageData = nil;
    
	if( format == CCRenderTextureImageFormatPNG )
		imageData = UIImagePNGRepresentation( image );
    
	else if( format == CCRenderTextureImageFormatJPEG )
		imageData = UIImageJPEGRepresentation(image, 0.9f);
    
	else
		NSAssert(NO, @"Unsupported format");
	
    
	success = [imageData writeToFile:fullPath atomically:YES];

	
#elif __CC_PLATFORM_MAC
	
	CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:fullPath];
	
	CGImageDestinationRef dest;

	if( format == CCRenderTextureImageFormatPNG )
		dest = 	CGImageDestinationCreateWithURL(url, kUTTypePNG, 1, NULL);

	else if( format == CCRenderTextureImageFormatJPEG )
		dest = 	CGImageDestinationCreateWithURL(url, kUTTypeJPEG, 1, NULL);

	else
		NSAssert(NO, @"Unsupported format");

	CGImageDestinationAddImage(dest, imageRef, nil);
		
	success = CGImageDestinationFinalize(dest);

	CFRelease(dest);
#endif

	CGImageRelease(imageRef);
	
	if( ! success )
		CCLOG(@"cocos2d: ERROR: Failed to save file:%@ to disk",fullPath);

	return success;
}


#if __CC_PLATFORM_IOS

-(UIImage *) getUIImage
{
	CGImageRef imageRef = [self newCGImage];
	
	CGFloat scale = [CCDirector sharedDirector].contentScaleFactor;
	UIImage* image	= [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
    
	CGImageRelease( imageRef );
    
	return image;
}
#endif // __CC_PLATFORM_IOS

- (CCColor*) clearColor
{
    return [CCColor colorWithGLKVector4:_clearColor];
}

- (void) setClearColor:(CCColor *)clearColor
{
    _clearColor = clearColor.glkVector4;
}

#pragma RenderTexture - Override

-(CGSize) contentSize
{
	return self.texture.contentSize;
}

-(void) setContentSize:(CGSize)size
{
	NSAssert(NO, @"You cannot change the content size of an already created CCRenderTexture. Recreate it");
}

@end
