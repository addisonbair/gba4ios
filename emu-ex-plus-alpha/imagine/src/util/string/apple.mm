#include <util/string/apple.h>
#import <Foundation/NSString.h>
#include <util/basicString.h>

void precomposeUnicodeString(const char *src, char *dest, uint destSize)
{
	auto decomp = [[NSString alloc] initWithBytesNoCopy:(void*)src length:strlen(src) encoding:NSUTF8StringEncoding freeWhenDone:false];
	@autoreleasepool
	{
		auto precomp = [decomp precomposedStringWithCanonicalMapping];
		string_copy(dest, [precomp UTF8String], destSize);
	}
}
