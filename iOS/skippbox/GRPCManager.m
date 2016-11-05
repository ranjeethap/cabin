//
//  GRPCManager.m
//  skippbox
//
//  Created by Remi Santos on 27/07/16.
//  Copyright © 2016 Azendoo. All rights reserved.
//

#import "GRPCManager.h"
#import "RCTLog.h"
#import <GRPCClient/GRPCCall+Tests.h>
#import <gRPC-ProtoRPC/ProtoRPC/ProtoRPC.h>
#import <AFNetworking/AFNetworking.h>
#import "hapi/services/Tiller.pbrpc.h"
#import "hapi/chart/Metadata.pbobjc.h"
#import "hapi/chart/Template.pbobjc.h"
#import "hapi/version/Version.pbobjc.h"

#import <NVHTarGzip/NVHTarGzip.h>
#import <YAMLThatWorks/YATWSerialization.h>
#import "Release+Dictionary.h"

static NSString* PROTO_VERSION = @"v2.0.0-rc.2";

@implementation GRPCManager

RCT_EXPORT_MODULE();

RCT_EXPORT_METHOD(fetchReleasesForHost:(NSString*)host
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [GRPCCall useInsecureConnectionsForHost:host];
  ReleaseService *service = [[ReleaseService alloc] initWithHost:host];
  ListReleasesRequest *request = [[ListReleasesRequest alloc] init];
  GRPCProtoCall *call = [service RPCToListReleasesWithRequest:request eventHandler:^(BOOL done, ListReleasesResponse * _Nullable response, NSError * _Nullable error) {
    if ((!done && response != nil) || (done && error != nil)) {
      if (error) {
        reject([@(error.code) stringValue], error.localizedDescription, error);
      } else {
        NSArray *releasesArray = [self releasesArrayFromResponse: response];
        resolve(releasesArray);
      }
    }
  }];
  [call.requestHeaders setObject:PROTO_VERSION forKey:@"x-helm-api-client"];
  [call start];
}

RCT_EXPORT_METHOD(deleteRelease:(NSString*)releaseName
                  forHost:(NSString*)host
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [GRPCCall useInsecureConnectionsForHost:host];
  ReleaseService *service = [[ReleaseService alloc] initWithHost:host];
  UninstallReleaseRequest *request = [[UninstallReleaseRequest alloc] init];
  request.name = releaseName;
  GRPCProtoCall *call = [service RPCToUninstallReleaseWithRequest:request handler:^(UninstallReleaseResponse * _Nullable response, NSError * _Nullable error) {
    if (error) {
      reject([@(error.code) stringValue], error.localizedDescription, error);
    } else {
      resolve(response.description);
    }
  }];
  [call.requestHeaders setObject:PROTO_VERSION forKey:@"x-helm-api-client"];
  [call start];
}

RCT_EXPORT_METHOD(deployChartAtURL:(NSString*)chartUrl
                      onHost:(NSString*)host
                      resolver:(RCTPromiseResolveBlock)resolve
                      rejecter:(RCTPromiseRejectBlock)reject)
{
  [GRPCCall useInsecureConnectionsForHost:host];
  ReleaseService *service = [[ReleaseService alloc] initWithHost:host];
  [self downloadFileAtUrl:chartUrl completion:^(NSURL *filePath) {
    NSURL *documentsDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    NSURL *toPath = [documentsDirectoryURL URLByAppendingPathComponent:@"chart"];
    NSError *error;
    NSLog(@"Decrompressing file...");
    BOOL untared = [[NVHTarGzip sharedInstance] unTarGzipFileAtPath:filePath.path toPath:toPath.path error:&error];
    if (error) {
      error ? NSLog(@"ERROR %@", [error description]) : NSLog(@"failed");
      reject([@(error.code) stringValue], [error localizedDescription], error);
      return;
    }
    if (!untared) {
      reject(0, @"Untar failed", nil);
      return;
    }

    NSLog(@"File decompressed at path %@", toPath.path);
    InstallReleaseRequest *request = [[InstallReleaseRequest alloc] init];
    [request setNamespace_p:@"default"];
    Chart *chart = [[Chart alloc] init];
    
    // Metadata
    NSString *chartYamlPath = [self searchFileWithName:@"Chart.yaml" inDirectory:toPath.path];
    NSData *chartData = [NSData dataWithContentsOfFile: chartYamlPath];
    NSDictionary *chartYaml = [YATWSerialization YAMLObjectWithData:chartData options:0 error:nil];
    Metadata *meta = [[Metadata alloc] init];
    meta.name = chartYaml[@"name"];
    meta.version = chartYaml[@"version"];
    meta.keywordsArray = chartYaml[@"keywoard"];
    meta.home = chartYaml[@"home"];
    meta.description_p = chartYaml[@"description"];
    [chart setMetadata:meta];
    
    // Templates
    NSMutableArray *templates = [NSMutableArray new];
    NSString *templatesPath = [self searchFileWithName:@"templates" inDirectory:toPath.path];
    NSArray *templatesDir = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:templatesPath error:nil];
    for (NSString *templatePath in templatesDir) {
      NSLog(@"Template: %@", templatePath);
      Template *template = [[Template alloc] init];
      template.name = templatePath;
      NSDictionary *templateDic = [YATWSerialization YAMLObjectWithData:[NSData dataWithContentsOfFile:[templatesPath stringByAppendingPathComponent:templatePath]] options:0 error:nil];
      template.data_p = [self dictionnaryToData:templateDic];
      [templates addObject:template];
    }
    [chart setTemplatesArray:templates];
    [request setChart:chart];
    GRPCProtoCall *call = [service RPCToInstallReleaseWithRequest:request handler:^(InstallReleaseResponse * _Nullable response, NSError * _Nullable error) {
      [[NSFileManager defaultManager] removeItemAtPath:toPath.path error:nil];
      [[NSFileManager defaultManager] removeItemAtPath:filePath.path error:nil];
      if (error) {
        reject([@(error.code) stringValue], error.localizedDescription, error);
      } else {
        resolve(response.description);
      }

    }];
    [call.requestHeaders setObject:PROTO_VERSION forKey:@"x-helm-api-client"];
    [call start];
  }];
}

- (NSString*)searchFileWithName:(NSString*)lastPath inDirectory:(NSString*)directory
{
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"self.lastPathComponent == %@", lastPath];
  NSArray *matchingPaths = [[[NSFileManager defaultManager] subpathsAtPath:directory] filteredArrayUsingPredicate:predicate];
  return [directory stringByAppendingPathComponent:matchingPaths.firstObject];
}


-(NSData*)dictionnaryToData:(NSDictionary *)params
{
  NSError *err;
  NSData *jsonData =[NSJSONSerialization dataWithJSONObject:params options:0 error:&err];
  
  NSString *jsonStr1 = [NSString stringWithUTF8String:[jsonData bytes]];
  jsonStr1 = [jsonStr1 stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
  
  NSData *jsonData2 =[jsonStr1 dataUsingEncoding:NSUTF8StringEncoding];
  
  return jsonData2 != nil ? jsonData2 : jsonData;
}

- (void)downloadFileAtUrl:(NSString*)url completion:(void (^)(NSURL *filePath))completion
{
  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
  AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
  
  NSURL *URL = [NSURL URLWithString:url];
  NSURLRequest *request = [NSURLRequest requestWithURL:URL];
  
  NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
    NSURL *documentsDirectoryURL = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:NO error:nil];
    return [documentsDirectoryURL URLByAppendingPathComponent:[response suggestedFilename]];
  } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
    completion(filePath);
  }];
  [downloadTask resume];
}


- (NSArray*)releasesArrayFromResponse:(ListReleasesResponse*)response {
  NSMutableArray *list = [NSMutableArray new];
  for (Release* release in response.releasesArray) {
    [list addObject:release.toDictionary];
  }
  return list;
}
@end
