#!/usr/bin/env python3
"""Section text ownership regression. Native UIKit still needs device testing.
Extracts the production layout method and runs it with adversarial ObjC stubs:
the superclass repopulates default labels on each layout, including reuse.
"""
import platform,re,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BAD='4ac149755d093995ce2b14f7971d8299d4df41ce'
CONTROLLERS=['VDTRootListController.m','VDTProcessConfiguration.m','VDTAboutListController.m','VDTApplicationListSubcontrollerController.m','ChoicyPreferences/CHPListController.m']

def own_titles(source):
    for part in ('Header','Footer'):
        pattern=r'-\s*\(NSString\s*\*\)tableView:\(UITableView\s*\*\)tableView titleFor'+part+r'InSection:\(NSInteger\)section\s*\{([^}]+)\}'
        m=re.search(pattern,source)
        assert m and m.group(1).strip()=='return nil;', 'inherited title path remains: '+part

def layout(source):
    start=source.index('@implementation VDTCompactSectionLabel')
    match=re.search(r'- \(void\)layoutSubviews \{.*?\n\}',source[start:],re.S)
    assert match,'no layout suppression for built-in labels'
    return match.group()

STUB=r'''
#include <objc/runtime.h>
#include <stdio.h>
#ifndef YES
#define YES ((BOOL)1)
#define NO ((BOOL)0)
#endif
__attribute__((objc_root_class))
@interface Label { Class isa; id _text; id _attributedText; BOOL _hidden; BOOL _isAccessibilityElement; }
+ (id)new;
@property(assign) id text;
@property(assign) id attributedText;
@property(assign) BOOL hidden;
@property(assign) BOOL isAccessibilityElement;
@end
@implementation Label
+ (id)new { return class_createInstance(self,0); }
@synthesize text=_text,attributedText=_attributedText,hidden=_hidden,isAccessibilityElement=_isAccessibilityElement;
@end
__attribute__((objc_root_class))
@interface HeaderBase { Class isa; Label *_textLabel; Label *_detailTextLabel; Label *_caption; }
+ (id)new;
@property(assign) Label *textLabel;
@property(assign) Label *detailTextLabel;
@property(assign) Label *caption;
- (void)layoutSubviews;
@end
@implementation HeaderBase
+ (id)new { HeaderBase *v=class_createInstance(self,0);v.textLabel=[Label new];v.detailTextLabel=[Label new];v.caption=[Label new];return v; }
@synthesize textLabel=_textLabel,detailTextLabel=_detailTextLabel,caption=_caption;
- (void)layoutSubviews {
 self.textLabel.text=(id)1;self.textLabel.attributedText=(id)2;self.textLabel.hidden=NO;self.textLabel.isAccessibilityElement=YES;
 self.detailTextLabel.text=(id)1;self.detailTextLabel.attributedText=(id)2;self.detailTextLabel.hidden=NO;self.detailTextLabel.isAccessibilityElement=YES;
}
@end
@interface VDTCompactSectionLabel : HeaderBase
@end
@implementation VDTCompactSectionLabel
METHOD
@end
int main(void) {
 VDTCompactSectionLabel *v=[VDTCompactSectionLabel new];
 for(int i=0;i<1000;i++) {
   id sentinel=(id)(unsigned long)(i+3);
   v.caption.text=sentinel;v.caption.hidden=NO;v.caption.isAccessibilityElement=YES;
   [v layoutSubviews];
   Label *a=v.textLabel,*b=v.detailTextLabel;
   if(a.text||a.attributedText||!a.hidden||a.isAccessibilityElement||b.text||b.attributedText||!b.hidden||b.isAccessibilityElement)return 17;
   if(v.caption.text!=sentinel||v.caption.hidden||!v.caption.isAccessibilityElement)return 18;
 }
 puts("production layout: 1000 repopulation/reuse cases passed (mock UIKit)");return 0;
}
'''

class SectionText(unittest.TestCase):
    def test_five_controllers_have_one_text_source(self):
        for f in CONTROLLERS:
            with self.subTest(file=f):own_titles((ROOT/'vedetteprefs'/f).read_text())
    def test_real_ui3_sources_rejected(self):
        for f in CONTROLLERS:
            old=subprocess.check_output(['git','show',BAD+':vedetteprefs/'+f],cwd=ROOT,text=True)
            with self.subTest(file=f),self.assertRaises(AssertionError):own_titles(old)
        old=subprocess.check_output(['git','show',BAD+':vedetteprefs/VDTStyle.m'],cwd=ROOT,text=True)
        with self.assertRaises(AssertionError):layout(old)
    def test_production_layout_survives_system_repopulation(self):
        method=layout((ROOT/'vedetteprefs/VDTStyle.m').read_text())
        args=['clang','-Wall','-Wextra','-Werror']
        if platform.system()=='Linux':
            include=subprocess.check_output(['gcc','-print-file-name=include'],text=True).strip()
            args+=['-I',include]
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            for name,body in [('current',method),('missing_suppression','- (void)layoutSubviews { [super layoutSubviews]; }')]:
                (p/'test.m').write_text(STUB.replace('METHOD',body))
                subprocess.run(args+[str(p/'test.m'),'-lobjc','-o',str(p/'test')],check=True)
                r=subprocess.run([str(p/'test')],capture_output=True,text=True)
                self.assertEqual(r.returncode,0 if name=='current' else 17)
                if name=='current':print(r.stdout.strip())

if __name__=='__main__':unittest.main(verbosity=2)
