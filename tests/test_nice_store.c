#define _POSIX_C_SOURCE 200809L
#include "../VDTNiceStore.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static void expectRead(VDTNiceStore *s, const char *name, const char *expected) {
    void *bytes = NULL; size_t length = 0;
    CHECK(VDTNiceStoreRead(s,name,&bytes,&length)==0);
    CHECK(length==strlen(expected)); CHECK(!memcmp(bytes,expected,length)); free(bytes);
}
int main(void) {
    if (geteuid()!=0) { fputs("root is required for root-owned isolated fixtures\n",stderr); return 77; }
    char root[]="/tmp/vedette-nice-store.XXXXXX"; CHECK(mkdtemp(root)!=NULL);
    char directory[512], moved[512], parent[512];
    snprintf(directory,sizeof(directory),"%s/state",root);
    snprintf(moved,sizeof(moved),"%s/moved",root);
    snprintf(parent,sizeof(parent),"%s/parent",root);
    VDTNiceStore s, other;
    CHECK(VDTNiceStoreOpen(directory,0,&s)==ENOENT);
    CHECK(VDTNiceStoreOpen(directory,1,&s)==0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"old",3)==0);
    expectRead(&s,VDT_NICE_JOURNAL,"old");
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"new",3)==0);
    expectRead(&s,VDT_NICE_JOURNAL,"new");
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_STATUS,"receipt",7)==0);
    expectRead(&s,VDT_NICE_STATUS,"receipt");
    struct stat st;
    CHECK(fstatat(s.directoryFD,VDT_NICE_JOURNAL,&st,0)==0 && (st.st_mode&0777)==0600 && st.st_uid==0);
    CHECK(fstatat(s.directoryFD,VDT_NICE_STATUS,&st,0)==0 && (st.st_mode&0777)==0644 && st.st_uid==0);
    CHECK(VDTNiceStoreWrite(&s,"../escape","x",1)==EINVAL);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,NULL,1)==EINVAL);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"x",VDT_NICE_STORE_LIMIT+1)==EINVAL);
    CHECK(VDTNiceStoreRemove(&s,VDT_NICE_JOURNAL)==0);
    CHECK(symlinkat(VDT_NICE_STATUS,s.directoryFD,VDT_NICE_JOURNAL)==0);
    void *bytes=NULL; size_t length=0;
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)!=0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"bad",3)!=0);
    CHECK(VDTNiceStoreRemove(&s,VDT_NICE_JOURNAL)!=0);
    expectRead(&s,VDT_NICE_STATUS,"receipt");
    CHECK(unlinkat(s.directoryFD,VDT_NICE_JOURNAL,0)==0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"original",8)==0);
    CHECK(linkat(s.directoryFD,VDT_NICE_JOURNAL,s.directoryFD,"hard",0)==0);
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)!=0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"bad",3)!=0);
    CHECK(unlinkat(s.directoryFD,"hard",0)==0);
    CHECK(fchmodat(s.directoryFD,VDT_NICE_JOURNAL,0666,0)==0);
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)!=0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"bad",3)!=0);
    CHECK(fchmodat(s.directoryFD,VDT_NICE_JOURNAL,0600,0)==0);
    CHECK(fchownat(s.directoryFD,VDT_NICE_JOURNAL,501,501,0)==0);
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)!=0);
    CHECK(fchownat(s.directoryFD,VDT_NICE_JOURNAL,0,0,0)==0);
    CHECK(VDTNiceStoreRemove(&s,VDT_NICE_JOURNAL)==0);
    CHECK(mkfifoat(s.directoryFD,VDT_NICE_JOURNAL,0600)==0);
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)!=0);
    CHECK(unlinkat(s.directoryFD,VDT_NICE_JOURNAL,0)==0);
    int fd=openat(s.directoryFD,VDT_NICE_JOURNAL,O_WRONLY|O_CREAT|O_EXCL,0600); CHECK(fd>=0);
    CHECK(ftruncate(fd,VDT_NICE_STORE_LIMIT+1)==0); CHECK(close(fd)==0);
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)!=0);
    CHECK(unlinkat(s.directoryFD,VDT_NICE_JOURNAL,0)==0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"original",8)==0);
    CHECK(rename(directory,moved)==0); CHECK(mkdir(directory,0755)==0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"detached",8)==ESTALE);
    CHECK(VDTNiceStoreRead(&s,VDT_NICE_JOURNAL,&bytes,&length)==ESTALE);
    CHECK(rmdir(directory)==0); CHECK(rename(moved,directory)==0);
    expectRead(&s,VDT_NICE_JOURNAL,"original");
    CHECK(chmod(directory,0777)==0); CHECK(VDTNiceStoreOpen(directory,0,&other)!=0);
    CHECK(VDTNiceStoreWrite(&s,VDT_NICE_JOURNAL,"bad",3)!=0); CHECK(chmod(directory,0755)==0);
    CHECK(symlink(directory,parent)==0); CHECK(VDTNiceStoreOpen(parent,0,&other)!=0); CHECK(unlink(parent)==0);
    CHECK(mkdir(parent,0777)==0); CHECK(chmod(parent,0777)==0);
    char unsafe[600]; snprintf(unsafe,sizeof(unsafe),"%s/state",parent);
    CHECK(VDTNiceStoreOpen(unsafe,1,&other)!=0);
    CHECK(rmdir(parent)==0);
    CHECK(VDTNiceStoreRemove(&s,VDT_NICE_JOURNAL)==0);
    CHECK(VDTNiceStoreRemove(&s,VDT_NICE_STATUS)==0);
    CHECK(VDTNiceStoreRemove(&s,VDT_NICE_REQUEST)==0);
    VDTNiceStoreClose(&s); VDTNiceStoreClose(&s);
    CHECK(rmdir(directory)==0); CHECK(rmdir(root)==0);
    printf("nice store: %u checks passed\n",checks); return 0;
}
