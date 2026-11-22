// Direct declarations of libmediainfo's C entry points. The upstream
// MediaInfoDLL.h resolves these through dlopen() and static function
// pointers, which does not import cleanly into Swift.
#include <stddef.h>
#include <wchar.h>

void *MediaInfo_New(void);
void MediaInfo_Delete(void *handle);
const wchar_t *MediaInfo_Inform(void *handle, size_t reserved);
const wchar_t *MediaInfo_Option(void *handle, const wchar_t *option, const wchar_t *value);

size_t MediaInfo_Open_Buffer_Init(void *handle, unsigned long long file_size, unsigned long long file_offset);
size_t MediaInfo_Open_Buffer_Continue(void *handle, const unsigned char *buffer, size_t buffer_size);
unsigned long long MediaInfo_Open_Buffer_Continue_GoTo_Get(void *handle);
size_t MediaInfo_Open_Buffer_Finalize(void *handle);
