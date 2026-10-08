#include "VDTDiagnostics.h"
#include <assert.h>
static int labels,payloads,calls,seen_label,seen_payload;
static __attribute__((used)) int label(void){return ++labels+10;}
static __attribute__((used)) int payload(void){return ++payloads+20;}
static __attribute__((used)) void emit(int l,int p){calls++;seen_label=l;seen_payload=p;}
int main(void){
  VDT_DIAGNOSTIC_CALL(emit,label(),payload());
#if VDT_DIAGNOSTICS_ENABLED
  assert(labels==1&&payloads==1&&calls==1&&seen_label==11&&seen_payload==21);
#else
  assert(labels==0&&payloads==0&&calls==0);
#endif
  VDT_DIAGNOSTIC_CALL(emit,label(),payload());
#if VDT_DIAGNOSTICS_ENABLED
  assert(labels==2&&payloads==2&&calls==2&&seen_label==12&&seen_payload==22);
#else
  assert(labels==0&&payloads==0&&calls==0);
#endif
  return 0;
}
