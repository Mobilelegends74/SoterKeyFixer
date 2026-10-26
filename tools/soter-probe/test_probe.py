import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
MOCK = r'''
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef struct {uint32_t code;} P;
static int b,c;
static bool mode(const char *s){const char *m=getenv("MOCK_MODE");return m&&strcmp(m,s)==0;}
void *AServiceManager_checkService(const char *name){if(strcmp(name,"vendor.qti.hardware.soter.ISoter/default")) abort();return mode("missing")?NULL:&b;}
void *AIBinder_Class_define(const char *s,void *a,void *d,void *t){(void)s;(void)a;(void)d;(void)t;return &c;}
bool AIBinder_associateClass(void *b,void *c){(void)b;(void)c;return !mode("descriptor");}
int32_t AIBinder_prepareTransaction(void *b,P **p){(void)b;*p=calloc(1,sizeof(P));return 0;}
int32_t AIBinder_transact(void *b,uint32_t code,P **in,P **out,uint32_t flags){
 (void)b;if(flags!=0x10000000u) abort();
 if(code!=14&&code!=16777214&&code!=16777215) abort();
 fprintf(stderr,"OP:%u\n",code);free(*in);*in=NULL;
 if(mode("dead")&&code==14)return -32;
 *out=calloc(1,sizeof(P));(*out)->code=code;return 0;
}
int32_t AParcel_readStatusHeader(const P *p,P **s){*s=malloc(sizeof(P));**s=*p;return 0;}
bool AStatus_isOk(const P *s){return !(mode("reply_error")&&s->code==14);}
int32_t AStatus_getStatus(const P *s){(void)s;return -32;}
int32_t AStatus_getExceptionCode(const P *s){(void)s;return -129;}
int32_t AParcel_readInt32(const P *p,int32_t *out){
 if(mode("malformed")&&p->code==14)return -22;
 *out=p->code==16777215?(mode("version")?2:1):(mode("failed")?-20:0);return 0;
}
int32_t AParcel_readString(const P *p,void *data,bool (*alloc)(void*,int32_t,char**)){
 (void)p;const char *s=mode("hash")?"incorrect":"81832c92aa802927e98f3bf426e95b03e5d7f5e6";char *buf=NULL;
 if(!alloc(data,(int32_t)strlen(s)+1,&buf)) return -12;strcpy(buf,s);return 0;
}
void AStatus_delete(P *p){free(p);}void AParcel_delete(P *p){free(p);}
void AIBinder_decStrong(void *p){(void)p;}
'''

class ProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.root=Path(cls.temp.name)
        (cls.root/'mock.c').write_text(MOCK)
        subprocess.run(['cc','-shared','-fPIC',str(cls.root/'mock.c'),'-o',str(cls.root/'libbinder_ndk.so')],check=True)
        cls.probe=cls.root/'probe'
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror',str(ROOT/'probe.c'),'-ldl','-o',str(cls.probe)],check=True)

    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def check_mode(self,mode,result,code,verify=True):
        r=subprocess.run([str(self.probe)],env=dict(os.environ,LD_LIBRARY_PATH=str(self.root),MOCK_MODE=mode),capture_output=True,text=True,timeout=3)
        self.assertEqual(r.returncode,code,r.stdout+r.stderr)
        self.assertIn(result,r.stdout)
        self.assertEqual('OP:14\n' in r.stderr,verify)
        if code: self.assertNotIn('DIRECT_VERIFY_OK',r.stdout)

    def test_actual_zero_response(self): self.check_mode('ok','DIRECT_VERIFY_OK',0)
    def test_key_error_separate_from_binder(self): self.check_mode('failed','"verify_result":-20',20)
    def test_dead_binder_never_becomes_zero_success(self): self.check_mode('dead','TRANSPORT_ERROR',13)
    def test_error_reply_never_becomes_zero_success(self): self.check_mode('reply_error','BINDER_REPLY_ERROR',13)
    def test_incomplete_reply_never_becomes_success(self): self.check_mode('malformed','MALFORMED_REPLY',13)
    def test_hash_mismatch_prevents_verify_transaction(self): self.check_mode('hash','UNSUPPORTED_INTERFACE',12,False)
    def test_version_mismatch_prevents_verify_transaction(self): self.check_mode('version','UNSUPPORTED_INTERFACE',12,False)
    def test_missing_service(self): self.check_mode('missing','SERVICE_UNAVAILABLE',11,False)
    def test_wrong_descriptor(self): self.check_mode('descriptor','INTERFACE_MISMATCH',12,False)

if __name__=='__main__':unittest.main()
