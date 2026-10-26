#import "hold.h"
#include <assert.h>
#include <string.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "hold.m"
int main(void) {
    assert(battery_parse_target("50\n",3)==50);
    assert(battery_parse_target("25",2)==25);
    assert(battery_parse_target("95\r\n",4)==95);
    const char *invalid[]={"24","96","100","50junk","50.0"," 50","5","off","+50","050","50\n0","50                "};
    for(size_t i=0;i<sizeof invalid/sizeof invalid[0];i++) assert(battery_parse_target(invalid[i],strlen(invalid[i]))==0);
    assert(battery_parse_target("50\0junk",7)==0);
    assert(battery_parse_target(NULL,0)==0);
    char temporary[]="/tmp/uniapi-battery-test.XXXXXX";
    assert(mkdtemp(temporary));
    int dir=open(temporary,O_RDONLY|O_DIRECTORY);
    int config=openat(dir,"target",O_WRONLY|O_CREAT|O_EXCL,0600);
    assert(config>=0 && write(config,"50\n",3)==3); close(config);
    assert(readTarget(dir)==50);
    assert(linkat(dir,"target",dir,"alias",0)==0);
    assert(readTarget(dir)==0); unlinkat(dir,"alias",0);
    unlinkat(dir,"target",0);
    assert(symlinkat("/dev/zero",dir,"target")==0);
    assert(readTarget(dir)==0); unlinkat(dir,"target",0);
    assert(mkfifoat(dir,"target",0600)==0);
    assert(readTarget(dir)==0); unlinkat(dir,"target",0);
    int sentinel=openat(dir,"sentinel",O_WRONLY|O_CREAT|O_EXCL,0600);
    assert(sentinel>=0 && write(sentinel,"safe",4)==4); close(sentinel);
    assert(linkat(dir,"sentinel",dir,"state.json",0)==0);
    assert(symlinkat("sentinel",dir,"state.new")==0);
    assert(report(dir,@{ @"state":@"off" }));
    sentinel=openat(dir,"sentinel",O_RDONLY);
    char preserved[4]; assert(read(sentinel,preserved,4)==4 && memcmp(preserved,"safe",4)==0); close(sentinel);
    unlinkat(dir,"state.json",0); unlinkat(dir,"sentinel",0);
    close(dir); rmdir(temporary);
    puts("battery target grammar passed");
}
