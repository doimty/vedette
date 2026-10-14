// Copyright (c) 2026 Vedette contributors. SPDX-License-Identifier: GPL-3.0-only
#include "VDTResourceSystemIO.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <limits.h>
#include <string.h>
typedef struct { int32_t pid, priority; uint64_t data; int32_t limit; uint32_t state; } Entry;
static int calls, writes, failControl, wrongSize, wrongPid, nonzeroData, changeAfter, identityCalls;
static bool allowed = true, alive = true;
static VDTMemlimitPair pair = {64,1,128,1};
static int32_t observedPriority = 18, requestedPriority;
static bool supported(void *x) { (void)x; return allowed; }
static bool identity(void *x,pid_t pid) { (void)x; (void)pid; ++identityCalls; return alive; }
static bool readToken(void *x,pid_t pid,VDTProcessInstanceToken *out) { (void)x; (void)pid; *out=(VDTProcessInstanceToken){10,20}; return alive; }
static int control(uint32_t cmd,int32_t pid,uint32_t flags,void *buf,size_t size) {
    ++calls; assert(pid == 42 && flags == 0);
    if (failControl) { memset(buf, 0xdd, size); errno=EPERM; return -1; }
    int result = 0;
    if (cmd==8) { assert(size==16); memcpy(buf,&pair,16); }
    else if (cmd==7) { assert(size==16); ++writes; memcpy(&pair,buf,16); }
    else if (cmd==1) { assert(size==24); Entry e={wrongPid?43:42,observedPriority,nonzeroData?7:0,64,0}; memcpy(buf,&e,24); result=wrongSize?12:24; }
    else {
        assert(cmd==2 && size==16); requestedPriority=*(int32_t *)buf;
        assert(requestedPriority>=-1 && ((uint32_t *)buf)[1]==0 && ((uint64_t *)buf)[1]==0); ++writes;
    }
    if (changeAfter) alive=false;
    return result;
}
int main(void) {
    const VDTResourceBackend *b=VDTResourceKernelBackend();
    VDTResourceSystemIO io={NULL,99,supported,identity,readToken,control,21};
    VDTMemlimitPair output={9,0,9,0}, sentinel=output;
    assert(b->getMemlimit(&io,42,&output) && output.active==64);
    assert(b->setMemlimit(&io,42,&pair) && writes==1);
    allowed=false; int old=calls;
    assert(!b->setMemlimit(&io,42,&pair) && calls==old);
    assert(!b->setPriority(&io,42,5) && calls==old);
    allowed=true;
    assert(!b->setMemlimit(&io,1,&pair) && calls==old);
    assert(!b->setPriority(&io,99,5) && calls==old);
    output=sentinel; failControl=1;
    assert(!b->getMemlimit(&io,42,&output) && !memcmp(&output,&sentinel,sizeof(output)));
    failControl=0; changeAfter=1; alive=true;
    assert(!b->getMemlimit(&io,42,&output) && !memcmp(&output,&sentinel,sizeof(output)));
    changeAfter=0; alive=true;
    VDTJetsamObservation priority={123};
    wrongSize=1; assert(!b->getPriority(&io,42,&priority) && priority.effectivePriority==123); wrongSize=0;
    wrongPid=1; assert(!b->getPriority(&io,42,&priority) && priority.effectivePriority==123); wrongPid=0;
    nonzeroData=1; old=writes; assert(!b->setPriority(&io,42,7) && writes==old); nonzeroData=0;
    assert(b->getPriority(&io,42,&priority) && priority.effectivePriority==18);
    assert(b->setPriority(&io,42,-1));
    old=writes; assert(!b->setPriority(&io,42,-2) && !b->setPriority(&io,42,22) && writes==old);
    VDTMemlimitPair invalid={0,0,64,0}; assert(!b->setMemlimit(&io,42,&invalid) && writes==old);
    invalid=(VDTMemlimitPair){64,2,128,0}; assert(!b->setMemlimit(&io,42,&invalid) && writes==old);
    assert(identityCalls>10);
    const int32_t versions[]={21,22,23,24,25,26,30,INT32_MAX};
    for (unsigned i=0;i<sizeof(versions)/sizeof(versions[0]);i++) {
        io.darwinMajor=versions[i]; int32_t max=versions[i]==21?21:210;
        observedPriority=versions[i]==21?18:180;
        priority.effectivePriority=999;
        assert(b->getPriority(&io,42,&priority) && priority.effectivePriority==observedPriority);
        assert(b->setPriority(&io,42,max) && requestedPriority==max);
        assert(b->setPriority(&io,42,versions[i]==21?13:150));
        old=writes; assert(!b->setPriority(&io,42,max+1) && writes==old);
        priority.effectivePriority=999; observedPriority=max+1;
        assert(!b->getPriority(&io,42,&priority) && priority.effectivePriority==999);
        observedPriority=max;
        assert(b->getMemlimit(&io,42,&output) && b->setMemlimit(&io,42,&pair));
    }
    io.darwinMajor=20; old=writes; priority.effectivePriority=999;
    assert(!b->getPriority(&io,42,&priority) && priority.effectivePriority==999);
    assert(!b->setPriority(&io,42,0) && writes==old);
    puts("PASS fixed transport: all iOS generations, 21/210 domains, identity/access gates, untouched failures, no userdata loss");
}
