#define _POSIX_C_SOURCE 200809L
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <dlfcn.h>

/* NDK Binder C ABI, checked against Android 15 binder headers. Manager lookup
 * is resolved dynamically, since it is not part of all NDK link stubs. */
typedef struct AIBinder B;
typedef struct AIBinder_Class C;
typedef struct AParcel P;
typedef struct AStatus S;
static B *(*lookup)(const char *);
static C *(*define_class)(const char *, void *(*)(void *), void (*)(void *), int32_t (*)(B *,uint32_t,const P *,P *));
static bool (*associate)(B *, const C *);
static int32_t (*prepare)(B *, P **);
static int32_t (*transact)(B *, uint32_t, P **, P **, uint32_t);
static int32_t (*read_status)(const P *, S **);
static bool (*is_ok)(const S *);
static int32_t (*get_status)(const S *);
static int32_t (*get_exception)(const S *);
static int32_t (*read_int)(const P *, int32_t *);
static int32_t (*read_string)(const P *, void *, bool (*)(void *,int32_t,char **));
static void (*delete_status)(S *);
static void (*delete_parcel)(P *);
static void (*release_binder)(B *);
static const char HASH[]="81832c92aa802927e98f3bf426e95b03e5d7f5e6";
static void *create(void *p) { return p; }
static void destroy(void *p) { (void)p; }
static int32_t reject(B *b,uint32_t c,const P *i,P *o) {
    (void)b;(void)c;(void)i;(void)o;return -74;
}
static void timed_out(int sig) {
    (void)sig;
    static const char msg[]="{\"result\":\"TIMEOUT\",\"key_health\":\"UNKNOWN\"}\n";
    (void)write(STDOUT_FILENO,msg,sizeof(msg)-1);_exit(124);
}
static bool allocate_string(void *data,int32_t n,char **buf) {
    if(n<=0 || n>128) return false;
    *buf=data;return true;
}
static bool call(B *b,uint32_t code,bool string,void *result) {
    P *in=NULL,*out=NULL; S *status=NULL;
    int32_t rc=prepare(b,&in);bool ok=false;
    if(rc==0) rc=transact(b,code,&in,&out,0x10000000u);
    if(rc!=0 || !out) {
        printf("{\"result\":\"TRANSPORT_ERROR\",\"operation\":%u,\"status\":%d,\"key_health\":\"UNKNOWN\"}\n",code,rc);
        goto done;
    }
    rc=read_status(out,&status);
    if(rc!=0 || !status || !is_ok(status)) {
        printf("{\"result\":\"BINDER_REPLY_ERROR\",\"operation\":%u,\"parcel_status\":%d,\"status\":%d,\"exception\":%d,\"key_health\":\"UNKNOWN\"}\n",
            code,rc,status?get_status(status):0,status?get_exception(status):0);
        goto done;
    }
    rc=string?read_string(out,result,allocate_string):read_int(out,result);
    if(rc!=0) printf("{\"result\":\"MALFORMED_REPLY\",\"operation\":%u,\"status\":%d,\"key_health\":\"UNKNOWN\"}\n",code,rc);
    else ok=true;
done:
    if(status) delete_status(status);
    if(in) delete_parcel(in);
    if(out) delete_parcel(out);
    return ok;
}
int main(void) {
    setvbuf(stdout,NULL,_IONBF,0);
    signal(SIGALRM,timed_out);alarm(15);
    void *lib=dlopen("libbinder_ndk.so",RTLD_NOW|RTLD_LOCAL);
    if(!lib) { puts("{\"result\":\"BINDER_LIBRARY_UNAVAILABLE\",\"key_health\":\"UNKNOWN\"}");return 10; }
#define LOAD(ptr,name) do { *(void **)(&ptr)=dlsym(lib,name); if(!ptr) { printf("Missing Binder API: %s\n",name);return 10; } } while(0)
    LOAD(lookup,"AServiceManager_checkService");LOAD(define_class,"AIBinder_Class_define");
    LOAD(associate,"AIBinder_associateClass");LOAD(prepare,"AIBinder_prepareTransaction");
    LOAD(transact,"AIBinder_transact");LOAD(read_status,"AParcel_readStatusHeader");
    LOAD(is_ok,"AStatus_isOk");LOAD(get_status,"AStatus_getStatus");LOAD(get_exception,"AStatus_getExceptionCode");
    LOAD(read_int,"AParcel_readInt32");LOAD(read_string,"AParcel_readString");
    LOAD(delete_status,"AStatus_delete");LOAD(delete_parcel,"AParcel_delete");LOAD(release_binder,"AIBinder_decStrong");
    B *b=lookup("vendor.qti.hardware.soter.ISoter/default");
    if(!b) { puts("{\"result\":\"SERVICE_UNAVAILABLE_OR_ACCESS_DENIED\",\"key_health\":\"UNKNOWN\"}");return 11; }
    C *c=define_class("vendor.qti.hardware.soter.ISoter",create,destroy,reject);
    if(!c || !associate(b,c)) {
        puts("{\"result\":\"INTERFACE_MISMATCH\",\"key_health\":\"UNKNOWN\"}");release_binder(b);return 12;
    }
    int32_t version=-1;char hash[128]={0};int exit_code=13;
    if(!call(b,16777215u,false,&version) || !call(b,16777214u,true,hash)) goto done;
    if(version!=1 || strcmp(hash,HASH)!=0) {
        puts("{\"result\":\"UNSUPPORTED_INTERFACE_VERSION_OR_HASH\",\"key_health\":\"UNKNOWN\"}");exit_code=12;goto done;
    }
    /* Transaction 14: verifyAttkKeyPair, checked in supplied BpSoter binary.
     * Only this verification and the two interface queries are reachable.
     * No generate/import/delete operations, service restarts or retries. */
    int32_t result=INT32_MIN;
    if(!call(b,14u,false,&result)) goto done;
    printf("{\"result\":\"%s\",\"binder\":\"OK\",\"interface_version\":1,\"verify_result\":%d}\n",
        result==0?"DIRECT_VERIFY_OK":"DIRECT_VERIFY_FAILED",result);
    exit_code=result==0?0:20;
done:
    release_binder(b);alarm(0);return exit_code;
}
