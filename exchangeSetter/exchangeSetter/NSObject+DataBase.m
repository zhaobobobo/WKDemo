//
//  NSObject+DataBase.m
//  exchangeSetter
//
//  Created by wangkun on 2017/12/18.
//  Copyright © 2017年 wangkun. All rights reserved.
//

#import "NSObject+DataBase.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "WKClassManager.h"
static void *WKDataBaseDealloKey;

static WKClassPropertyModel * getPropertyModel(id self, SEL _cmd)
{
    NSArray <WKClassPropertyModel *> * arr = [WKClassManager getClassPropertysWithClass:[self class]];
    
    NSString * setter = NSStringFromSelector(_cmd);
    
    WKClassPropertyModel * selectedModel = nil;
    for (WKClassPropertyModel * model in arr) {
        if([model.setterName isEqualToString:setter])
        {
            selectedModel = model;
            break;
        }
    }
    return selectedModel;
}

static Ivar getIvar(id self, SEL _cmd)
{
    WKClassPropertyModel * selectedModel = getPropertyModel(self, _cmd);
    if (!selectedModel) {
        return NULL;
    }
    //拼接变量名
    NSString * varName = selectedModel.varName;
    
    unsigned int count = 0;
    //得到变量列表
    Ivar * members = class_copyIvarList([self class], &count);
    
    int index = -1;
    //遍历变量
    for (int i = 0 ; i < count; i++) {
        Ivar var = members[i];
        //获得变量名
        const char *memberName = ivar_getName(var);
        //生成string
        NSString * memberNameStr = [NSString stringWithUTF8String:memberName];
        if ([varName isEqualToString:memberNameStr]) {
            index = i;
            break ;
        }
    }
    if (index > -1) {
        return members[index];
    }
    else
    {
        return NULL;
    }
}



static void new_setter_object(id self, SEL _cmd, id newValue)
{
    Ivar member = getIvar(self, _cmd);
    //变量存在则赋值
    if (member != NULL) {
        object_setIvar(self, member, newValue);
        NSLog(@"修改成功");
        WKClassPropertyModel * model = getPropertyModel(self, _cmd);
        void (*func)(id, SEL,id) = (void *)model.oldsetterIMP;
        func(self,_cmd,newValue);
        NSObject * tmpObj = self;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveToLocal) object:nil];
        [tmpObj.saveKeyValue setObject:newValue forKey:model.name ?: [NSString stringWithUTF8String:ivar_getName(member)]];
        [tmpObj performSelector:@selector(saveToLocal) withObject:nil afterDelay:tmpObj.saveiIntervaltime];

    }
}

static void new_setter_long(id self, SEL _cmd, long long newValue)
{
    Ivar member = getIvar(self, _cmd);
    //变量存在则赋值
    if (member != NULL) {
        object_setIvar(self,member,(__bridge id)((void*)newValue));
        NSLog(@"修改成功");
        WKClassPropertyModel * model = getPropertyModel(self, _cmd);
        void (*func)(id, SEL,long long) = (void *)model.oldsetterIMP;
        func(self,_cmd,newValue);
        
        NSObject * tmpObj = self;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveToLocal) object:nil];
        [tmpObj.saveKeyValue setObject:@(newValue) forKey:model.name ?: [NSString stringWithUTF8String:ivar_getName(member)]];
        [tmpObj performSelector:@selector(saveToLocal) withObject:nil afterDelay:tmpObj.saveiIntervaltime];
    }
}

@implementation NSObject (DataBase)

+ (void)wk_exchangeSetter
{
    NSArray <WKClassPropertyModel *> * arr = [WKClassManager getClassPropertysWithClass:[self class]];
    NSArray <WKClassMethodModel *> * methods = [WKClassManager getClassMethodsWithClass:[self class]];
    for (WKClassMethodModel * methodModel in methods) {
        for (WKClassPropertyModel * model in arr) {
            if([model.setterName isEqualToString:methodModel.name])
            {
                if (model.type == WKPropertyType_Object)
                {
                    method_setImplementation(methodModel.method, (IMP)new_setter_object);
                }
                else if (model.type == WKPropertyType_CNumber)
                {
                    method_setImplementation(methodModel.method, (IMP)new_setter_long);
                }
            }
        }
    }
}

- (void)setSaveKeyValue:(NSMutableDictionary *)saveKeyValue
{
    objc_setAssociatedObject(self, @selector(saveKeyValue), saveKeyValue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @autoreleasepool {
        // Need to removeObserver in dealloc
        if (objc_getAssociatedObject(self, &WKDataBaseDealloKey) == nil) {
            __unsafe_unretained typeof(self) weakSelf = self; // NOTE: need to be __unsafe_unretained because __weak var will be reset to nil in dealloc
            id deallocHelper = [self addDeallocBlock:^{
                //移除线程操作
                
                [NSObject cancelPreviousPerformRequestsWithTarget:weakSelf selector:@selector(saveToLocal) object:nil];
                //存储到本地
                [weakSelf saveToLocal];
            }];
            objc_setAssociatedObject(self, &WKDataBaseDealloKey, deallocHelper, OBJC_ASSOCIATION_ASSIGN);
        }
    }
}

- (NSMutableDictionary *)saveKeyValue
{
    id obj = objc_getAssociatedObject(self, @selector(saveKeyValue));
    if (!obj || ![obj isKindOfClass:[NSMutableDictionary class]]) {
        obj = [NSMutableDictionary dictionary];
        [self setSaveKeyValue:obj];
    }
    return obj;
}

- (void)setSaveiIntervaltime:(NSTimeInterval)saveiIntervaltime
{
    objc_setAssociatedObject(self, @selector(saveiIntervaltime),@(saveiIntervaltime), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSTimeInterval)saveiIntervaltime
{
    id obj = objc_getAssociatedObject(self, @selector(saveiIntervaltime));
    if (!obj || ![obj isKindOfClass:[NSNumber class]]) {
        obj = @(5);
        [self setSaveiIntervaltime:[obj doubleValue]];
    }
    return [obj doubleValue];
}

- (void)saveToLocal
{
    
    BOOL isCanSave = [self isShouldSave];
    if (!isCanSave) {
        return;
    }
    //需要存储的时候，判断表存不存在，不存在则创建，存在则取数据更新
    NSLog(@"存储位置");
    
    NSLog(@"%@",self.saveKeyValue);
    //存储完后 移除
    [self.saveKeyValue removeAllObjects];
}

- (BOOL)isShouldSave
{
    if (self.saveKeyValue.count <= 0) {
        return NO;
    }
    
    NSArray * mainKey = [[self class] DBMainKey];
    if (!mainKey || mainKey.count <= 0 ) {
        return NO;
    }
    NSArray <WKClassPropertyModel *> * arr = [WKClassManager getClassPropertysWithClass:[self class]];
    for (NSString * pn in mainKey)
    {
        for (WKClassPropertyModel * model in arr)
        {
            if([model.name isEqualToString:pn])
            {
                switch (model.type) {
                    case WKPropertyType_Object:
                    {
                        id value = [self valueForKey:pn];
                        if (value != nil)
                        {
                            id value = ((id (*)(id, SEL))(void *) objc_msgSend)((id)self, NSSelectorFromString (model.getterName));
                            NSAssert(value, @"主键不能为空");
                            [self.saveKeyValue setObject:value forKey:pn];
                            
                        }
                        else
                        {
                            return NO;
                        }
                    }
                        break;
                    case WKPropertyType_CNumber:
                    {
                        long long num = ((bool (*)(id, SEL))(void *) objc_msgSend)((id)self, NSSelectorFromString (model.getterName));
                        [self.saveKeyValue setObject:@(num) forKey:pn];
                    }
                        break;
                    default:
                        NSAssert(NO, @"主键类型不正确");
                        break;
                }
                
            }
        }
    }
    return YES;
}

+ (NSArray *)DBMainKey
{
    return nil;
}

@end
