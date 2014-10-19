
@interface UrlBackOffEntry : NSObject
@property (nonatomic) NSDate *nextAttemptAt;
@property (nonatomic) NSTimeInterval duration;
@end
@implementation UrlBackOffEntry
@end

@interface API ()
{
	NSOperationQueue *requestQueue;
	NSDateFormatter *mediumFormatter;
    NSString *cacheDirectory;

#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	NSInteger networkIndicationCount;
	CGFloat GLOBAL_SCREEN_SCALE;
#endif

	NSMutableDictionary *badLinks;
}
@end

@implementation API

#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED
	#define CACHE_MEMORY 1024*1024*4
	#define CACHE_DISK 1024*1024*128
#else
	#define CACHE_MEMORY 1024*1024*2
	#define CACHE_DISK 1024*1024*8
#endif

#define CALLBACK if(callback) callback

typedef void (^completionBlockType)(BOOL);

- (id)init
{
    self = [super init];
    if (self)
	{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
		GLOBAL_SCREEN_SCALE = [UIScreen mainScreen].scale;
#endif
		NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:CACHE_MEMORY
														  diskCapacity:CACHE_DISK
															  diskPath:nil];
		[NSURLCache setSharedURLCache:cache];

		mediumFormatter = [[NSDateFormatter alloc] init];
		mediumFormatter.dateStyle = NSDateFormatterMediumStyle;
		mediumFormatter.timeStyle = NSDateFormatterMediumStyle;

		requestQueue = [[NSOperationQueue alloc] init];
		requestQueue.maxConcurrentOperationCount = 4;

		badLinks = [NSMutableDictionary new];

		self.reachability = [Reachability reachabilityForInternetConnection];
		[self.reachability startNotifier];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *appSupportURL = [[fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
        appSupportURL = [appSupportURL URLByAppendingPathComponent:@"com.housetrip.Trailer"];
        cacheDirectory = appSupportURL.path;

        if([fileManager fileExistsAtPath:cacheDirectory])
            [self clearImageCache];
        else
            [fileManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
	}
    return self;
}

- (void)error:(NSString*)errorString
{
	DLog(@"Failed to fetch %@",errorString);
}

- (void)updateLimitsFromServer
{
	NSArray *allApiServers = [ApiServer allApiServersInMoc:app.dataManager.managedObjectContext];
	NSInteger total = allApiServers.count;
	__block NSInteger count = 0;
	for(ApiServer *apiServer in allApiServers)
	{
		if(apiServer.authToken.length)
		{
			[self getRateLimitFromServer:(ApiServer *)apiServer andCallback:^(long long remaining, long long limit, long long reset) {
				apiServer.requestsRemaining = @(remaining);
				apiServer.requestsLimit = @(limit);
				count++;
				if(count==total)
				{
					[[NSNotificationCenter defaultCenter] postNotificationName:API_USAGE_UPDATE
																		object:apiServer
																	  userInfo:nil];
				}
			}];
		}
	}
}

- (void)fetchStatusesForCurrentPullRequestsToMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	NSArray *prs = [DataItem allItemsOfType:@"PullRequest" inMoc:moc];

	if(!prs.count)
	{
		CALLBACK(YES);
		return;
	}

	for(PullRequest *r in prs)
		for(PRStatus *s in r.statuses)
			s.postSyncAction = @(kPostSyncDelete);

	NSInteger total = prs.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	for(PullRequest *p in prs)
	{
		[self getPagedDataInPath:p.statusesLink
					  fromServer:p.apiServer
				startingFromPage:1
						  params:nil
					extraHeaders:nil
				 perPageCallback:^BOOL(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 PRStatus *s = [PRStatus statusWithInfo:info fromServer:p.apiServer];
						 s.pullRequest = p;
					 }
					 return NO;
				 } finalCallback:^(BOOL success, NSInteger resultCode, NSString *etag) {
					 if(success) succeeded++; else failed++;
					 if(succeeded+failed==total)
					 {
						 if(failed==0)
						 {
							 [DataItem nukeDeletedItemsOfType:@"PRStatus" inMoc:moc];
							 CALLBACK(YES);
						 }
						 else
						 {
							 CALLBACK(NO);
						 }
					 }
				 }];
	}
}

- (void)fetchCommentsForCurrentPullRequestsToMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	NSArray *prs = [DataItem newOrUpdatedItemsOfType:@"PullRequest" inMoc:moc];
	for(PullRequest *r in prs)
		for(PRComment *c in r.comments)
			c.postSyncAction = @(kPostSyncDelete);

	NSInteger totalOperations = 2;
	__block NSInteger succeded = 0;
	__block NSInteger failed = 0;

	completionBlockType completionCallback = ^(BOOL success){
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			[DataItem nukeDeletedItemsOfType:@"PRComment" inMoc:moc];
			CALLBACK(failed==0);
		}
	};

	[self _fetchCommentsForPullRequests:prs issues:YES inMoc:moc andCallback:completionCallback];

	[self _fetchCommentsForPullRequests:prs issues:NO inMoc:moc andCallback:completionCallback];
}

- (void)_fetchCommentsForPullRequests:(NSArray*)prs
							   issues:(BOOL)issues
								inMoc:(NSManagedObjectContext *)moc
						  andCallback:(void(^)(BOOL success))callback
{
	NSInteger total = prs.count;
	if(!total)
	{
		CALLBACK(YES);
		return;
	}

	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	for(PullRequest *p in prs)
	{
		NSString *link;
		if(issues)
			link = p.issueCommentLink;
		else
			link = p.reviewCommentLink;

		[self getPagedDataInPath:link
					  fromServer:p.apiServer
				startingFromPage:1
						  params:nil
					extraHeaders:nil
				 perPageCallback:^BOOL(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 PRComment *c = [PRComment commentWithInfo:info fromServer:p.apiServer];
						 c.pullRequest = p;

						 // check if we're assigned to a just created pull request, in which case we want to "fast forward" its latest comment dates to our own if we're newer
						 if(p.postSyncAction.integerValue == kPostSyncNoteNew)
						 {
							 NSDate *commentCreation = c.createdAt;
							 if(!p.latestReadCommentDate || [p.latestReadCommentDate compare:commentCreation]==NSOrderedAscending)
								 p.latestReadCommentDate = commentCreation;
						 }
					 }
					 return NO;
				 } finalCallback:^(BOOL success, NSInteger resultCode, NSString *etag) {
					 if(success) succeeded++; else failed++;
					 if(succeeded+failed==total)
					 {
						 callback(failed==0);
					 }
				 }];
	}
}

- (void)fetchRepositoriesToMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	[self syncUserDetailsInMoc:moc andCallback:^(BOOL success) {
		if(success)
		{
			NSArray *allApiServers = [ApiServer allApiServersInMoc:moc];
			NSInteger totalOperations = allApiServers.count;
			__block NSInteger succeeded = 0;
			__block NSInteger failed = 0;

			completionBlockType completionCallback = ^(BOOL success) {
				if(success) succeeded++; else failed++;
				if(succeeded+failed==totalOperations)
				{
					BOOL success = (failed==0);

					if(success)
					{
						[DataItem nukeDeletedItemsOfType:@"Repo" inMoc:moc];
					}

					BOOL shouldHideByDefault = settings.hideNewRepositories;
					for(Repo *r in [DataItem newItemsOfType:@"Repo" inMoc:moc])
					{
						r.hidden = @(shouldHideByDefault);
						if(!shouldHideByDefault)
						{
							[app postNotificationOfType:kNewRepoAnnouncement forItem:r];
						}
					}

					app.lastRepoCheck = [NSDate date];
					CALLBACK(success);
				}
			};

			NSArray *allRepos = [PullRequest itemsOfType:@"Repo" surviving:YES inMoc:moc];
			for(Repo *r in allRepos) r.postSyncAction = @(kPostSyncDelete);

			NSArray *inaccessibleRepos = [Repo inaccessibleReposInMoc:moc];
			for(Repo *r in inaccessibleRepos) r.inaccessible = @NO;

			for(ApiServer *apiServer in allApiServers)
			{
				[self syncWatchedReposFromServer:apiServer andCallback:completionCallback];
			}
		}
		else CALLBACK(NO);
	}];
}

- (void)detectAssignedPullRequestsInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSArray *prs = [DataItem newOrUpdatedItemsOfType:@"PullRequest" inMoc:moc];

	if(!prs.count)
	{
		CALLBACK(YES);
		return;
	}

	for(PullRequest *r in prs)
		for(PRStatus *s in r.statuses)
			s.postSyncAction = @(kPostSyncDelete);

	NSInteger totalOperations = prs.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeeded++; else failed++;
		if(succeeded+failed==totalOperations)
		{
			CALLBACK(failed==0);
		}
	};

	for(PullRequest *p in prs)
	{
		if(p.issueUrl)
		{
			[self getDataInPath:p.issueUrl
					 fromServer:p.apiServer
						 params:nil
				   extraHeaders:nil
					andCallback:^(id data, BOOL lastPage, NSInteger resultCode, NSString *etag) {
						if(data)
						{
							NSString *assignee = [[data ofk:@"assignee"] ofk:@"login"];
							BOOL assigned = [assignee isEqualToString:p.apiServer.userName];
							p.isNewAssignment = @(assigned && !p.assignedToMe.boolValue);
							p.assignedToMe = @(assigned);
							completionCallback(YES);
						}
						else
						{
							if(resultCode == 404 || resultCode == 410)
							{
								// 404/410 is fine, it means issue entry doesn't exist
								p.assignedToMe = @NO;
								p.isNewAssignment = @NO;
								completionCallback(YES);
							}
							else
							{
								completionCallback(NO);
							}
						}
					}];
		}
		else
		{
			completionCallback(YES);
		}
	}
}

- (void)checkPrClosuresInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:@"PullRequest"];
	f.predicate = [NSPredicate predicateWithFormat:@"postSyncAction == %d and condition == %d",kPostSyncDelete, kPullRequestConditionOpen];
	f.returnsObjectsAsFaults = NO;
	NSArray *pullRequests = [moc executeFetchRequest:f error:nil];

	NSArray *prsToCheck = [pullRequests filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(PullRequest *r, NSDictionary *bindings) {
		Repo *parent = r.repo;
		return (!parent.hidden.boolValue) && (parent.postSyncAction.integerValue!=kPostSyncDelete);
	}]];

	NSInteger totalOperations = prsToCheck.count;
	if(totalOperations==0)
	{
		callback(YES);
		return;
	}

	__block NSInteger succeded = 0;
	__block NSInteger failed = 0;

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			CALLBACK(failed==0);
		}
	};

	for(PullRequest *r in prsToCheck)
		[self investigatePrClosureForPr:r andCallback:completionCallback];
}

- (void)investigatePrClosureForPr:(PullRequest *)r andCallback:(void(^)(BOOL success))callback
{
	DLog(@"Checking closed PR to see if it was merged: %@",r.title);

	[self get:[NSString stringWithFormat:@"/repos/%@/pulls/%@", r.repo.fullName, r.number]
   fromServer:r.apiServer
   parameters:nil
 extraHeaders:nil
	  success:^(NSHTTPURLResponse *response, id data) {

		  NSDictionary *mergeInfo = [data ofk:@"merged_by"];
		  if(mergeInfo)
		  {
			  DLog(@"detected merged PR: %@",r.title);
			  NSNumber *mergeUserId = [mergeInfo  ofk:@"id"];
			  DLog(@"merged by user id: %@, our id is: %@", mergeUserId, r.apiServer.userId);
			  BOOL mergedByMyself = [mergeUserId isEqualToNumber:r.apiServer.userId];
			  if(!(settings.dontKeepPrsMergedByMe && mergedByMyself))
			  {
				  DLog(@"detected merged PR: %@",r.title);
				  switch (settings.mergeHandlingPolicy)
				  {
					  case kPullRequestHandlingKeepMine:
					  {
						  if(r.sectionIndex.integerValue==kPullRequestSectionAll) break;
					  }
					  case kPullRequestHandlingKeepAll:
					  {
						  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this
						  r.condition = @kPullRequestConditionMerged;
						  [app postNotificationOfType:kPrMerged forItem:r];
					  }
					  case kPullRequestHandlingKeepNone: {}
				  }
			  }
			  else
			  {
				  DLog(@"will not announce merged PR: %@",r.title);
			  }
		  }
		  else
		  {
			  DLog(@"detected closed PR: %@",r.title);
			  switch(settings.closeHandlingPolicy)
			  {
				  case kPullRequestHandlingKeepMine:
				  {
					  if(r.sectionIndex.integerValue==kPullRequestSectionAll) break;
				  }
				  case kPullRequestHandlingKeepAll:
				  {
					  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this
					  r.condition = @kPullRequestConditionClosed;
					  [app postNotificationOfType:kPrClosed forItem:r];
				  }
				  case kPullRequestHandlingKeepNone: {}
			  }
		  }
		  CALLBACK(YES);

	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this, we couldn't check, play it safe
		  CALLBACK(NO);
	  }];
}

- (void)fetchPullRequestsForActiveReposWithRepoRefresh:(BOOL)doRepoRefresh
										   andCallback:(void(^)(BOOL success))callback
{
	NSManagedObjectContext *syncContext = [app.dataManager tempContext];
	if(doRepoRefresh)
	{
		[self fetchRepositoriesToMoc:syncContext andCallback:^(BOOL success) {
			[self syncToMoc:syncContext andCallback:callback];
		}];
	}
	else
	{
		[self syncToMoc:syncContext andCallback:callback];
	}
}

extern NSDateFormatter *_syncDateFormatter;

- (void)markDirtyRepoIds:(NSMutableSet *)repoIdsToMarkDirty
usingReceivedEventsFromServer:(ApiServer *)apiServer
			 andCallback:(void(^)(BOOL success))callback
{
	NSString *latestEtag = apiServer.latestReceivedEventEtag;
	NSDate *latestDate = apiServer.latestReceivedEventDateProcessed;

	apiServer.latestReceivedEventDateProcessed = latestDate;
	BOOL needFirstDateOnly = ([latestDate isEqualToDate:[NSDate distantPast]]);

	[self getPagedDataInPath:[NSString stringWithFormat:@"/users/%@/received_events",apiServer.userName]
				  fromServer:apiServer
			startingFromPage:1
					  params:nil
				extraHeaders:latestEtag ? @{ @"If-None-Match": latestEtag } : nil
			 perPageCallback:^BOOL(id data, BOOL lastPage) {
				 for(NSDictionary *d in data)
				 {
					 NSDate *eventDate = [_syncDateFormatter dateFromString:d[@"created_at"]];
					 if([latestDate compare:eventDate]==NSOrderedAscending) // this is where we came in
					 {
						 DLog(@"New event at %@",eventDate);
						 NSNumber *repoId = d[@"repo"][@"id"];
						 if(repoId) [repoIdsToMarkDirty addObject:repoId];
						 if([apiServer.latestReceivedEventDateProcessed compare:eventDate]==NSOrderedAscending)
						 {
							 apiServer.latestReceivedEventDateProcessed = eventDate;
							 if(needFirstDateOnly)
							 {
								 DLog(@"First sync, all repos are dirty so we don't need to read further, we have the latest received event date: %@",apiServer.latestReceivedEventDateProcessed);
								 return YES;
							 }
						 }
					 }
					 else
					 {
						 DLog(@"The rest of these received events we've processed, stopping event parsing");
						 return YES;
					 }
				 }
				 return NO;
			 } finalCallback:^(BOOL success, NSInteger resultCode, NSString *etag) {
				 apiServer.latestReceivedEventEtag = etag;
				 CALLBACK(success);
			 }];
}

- (void)markDirtyRepoIds:(NSMutableSet *)repoIdsToMarkDirty
	usingUserEventsFromServer:(ApiServer *)apiServer
			 andCallback:(void(^)(BOOL success))callback
{
	NSString *latestEtag = apiServer.latestUserEventEtag;
	NSDate *latestDate = apiServer.latestUserEventDateProcessed;

	apiServer.latestUserEventDateProcessed = latestDate;
	BOOL needFirstDateOnly = ([latestDate isEqualToDate:[NSDate distantPast]]);

	[self getPagedDataInPath:[NSString stringWithFormat:@"/users/%@/events",apiServer.userName]
				  fromServer:apiServer
			startingFromPage:1
					  params:nil
				extraHeaders:latestEtag ? @{ @"If-None-Match": latestEtag } : nil
			 perPageCallback:^BOOL(id data, BOOL lastPage) {
				 for(NSDictionary *d in data)
				 {
					 NSDate *eventDate = [_syncDateFormatter dateFromString:d[@"created_at"]];
					 if([latestDate compare:eventDate]==NSOrderedAscending) // this is where we came in
					 {
						 DLog(@"New event at %@",eventDate);
						 NSNumber *repoId = d[@"repo"][@"id"];
						 if(repoId) [repoIdsToMarkDirty addObject:repoId];
						 if([apiServer.latestUserEventDateProcessed compare:eventDate]==NSOrderedAscending)
						 {
							 apiServer.latestUserEventDateProcessed = eventDate;
							 if(needFirstDateOnly)
							 {
								 DLog(@"First sync, all repos are dirty so we don't need to read further, we have the latest user event date: %@",apiServer.latestUserEventDateProcessed);
								 return YES;
							 }
						 }
					 }
					 else
					 {
						 DLog(@"The rest of these user events we've processed, stopping event parsing");
						 return YES;
					 }
				 }
				 return NO;
			 } finalCallback:^(BOOL success, NSInteger resultCode, NSString *etag) {
				 apiServer.latestUserEventEtag = etag;
				 CALLBACK(success);
			 }];
}

- (void)markDirtyReposInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSArray *allApiServers = [ApiServer allApiServersInMoc:moc];

	NSInteger totalOperations = 2*allApiServers.count;

	__block NSInteger succeded = 0, failed = 0;

	NSMutableSet *repoIdsToMarkDirty = [NSMutableSet set];

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			BOOL ok = (failed==0);
			if(ok)
			{
				[Repo markDirtyReposWithIds:repoIdsToMarkDirty inMoc:moc];

				if(repoIdsToMarkDirty.count>0) DLog(@"Marked dirty %ld repos which have events in their event stream", (long)repoIdsToMarkDirty.count);

				[self markLongCleanReposAsDirtyInMoc:moc];
			}
			CALLBACK(ok);
		}
	};

	for(ApiServer *apiServer in allApiServers)
	{
		if(apiServer.goodToGo)
		{
			[self markDirtyRepoIds:repoIdsToMarkDirty usingUserEventsFromServer:apiServer andCallback:completionCallback];
			[self markDirtyRepoIds:repoIdsToMarkDirty usingReceivedEventsFromServer:apiServer andCallback:completionCallback];
		}
	}
}

- (void)markLongCleanReposAsDirtyInMoc:(NSManagedObjectContext *)moc
{
	NSFetchRequest *f = [NSFetchRequest fetchRequestWithEntityName:@"Repo"];
	f.predicate = [NSPredicate predicateWithFormat:@"dirty != YES and lastDirtied < %@", [NSDate dateWithTimeInterval:-3600 sinceDate:[NSDate date]]];
	f.includesPropertyValues = NO;
	f.returnsObjectsAsFaults = NO;
	NSArray *reposNotFetchedRecently = [moc executeFetchRequest:f error:nil];
	for(Repo *r in reposNotFetchedRecently)
	{
		r.dirty = @YES;
		r.lastDirtied = [NSDate date];
	}

	if(reposNotFetchedRecently.count>0)
	{
		DLog(@"Marked dirty %ld repos which haven't been refreshed in over an hour", (long)reposNotFetchedRecently.count);
	}
}

- (void)syncToMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	[self markDirtyReposInMoc:moc
				  andCallback:^(BOOL success) {
					  if(success)
					  {
						  for(Repo *r in [Repo unsyncableReposInMoc:moc])
							  for(PullRequest *p in r.pullRequests)
								  [moc deleteObject:p];

						  [self fetchPullRequestsForRepos:[Repo syncableReposInMoc:moc]
													toMoc:moc
											  andCallback:^(BOOL success) {
												  if(success)
												  {
													  [self updatePullRequestsInMoc:moc andCallback:^(BOOL success) {
														  if(success) [self syncSucceededInMoc:moc];
														  CALLBACK(success);
													  }];
												  }
												  else CALLBACK(NO);
											  }];
					  }
					  else CALLBACK(NO);
				  }];
}

- (void)syncSucceededInMoc:(NSManagedObjectContext *)moc
{
	// do not cleanup PRs before because some "deleted" ones will turn to merged or closed ones
	[DataItem nukeDeletedItemsOfType:@"Repo" inMoc:moc];
	[DataItem nukeDeletedItemsOfType:@"PullRequest" inMoc:moc];

	NSArray *surviving = [PullRequest itemsOfType:@"PullRequest" surviving:YES inMoc:moc];
	for(PullRequest *r in surviving) [r postProcess];

	if(moc.hasChanges)
	{
		DLog(@"Database dirty after sync, saving");
		NSError *error = nil;
		[moc save:&error];
	}
	else
	{
		DLog(@"No database changes after sync");
	}

	if(settings.showStatusItems)
	{
		self.successfulRefreshesSinceLastStatusCheck++;
	}
}

- (void)updatePullRequestsInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	BOOL willScanForStatuses = [self shouldScanForStatusesInMoc:moc];

	NSInteger totalOperations = 3;
	if(willScanForStatuses) totalOperations++;

	__block NSInteger succeded = 0, failed = 0;

	completionBlockType completionCallback = ^(BOOL success) {
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			CALLBACK(failed==0);
		}
	};

	if(willScanForStatuses)
		[self fetchStatusesForCurrentPullRequestsToMoc:moc andCallback:completionCallback];

	[self fetchCommentsForCurrentPullRequestsToMoc:moc andCallback:completionCallback];
	[self checkPrClosuresInMoc:moc andCallback:completionCallback];
	[self detectAssignedPullRequestsInMoc:moc andCallback:completionCallback];
}

- (BOOL)shouldScanForStatusesInMoc:(NSManagedObjectContext *)moc
{
	if(self.successfulRefreshesSinceLastStatusCheck % settings.statusItemRefreshInterval == 0)
	{
		if(settings.showStatusItems)
		{
			self.successfulRefreshesSinceLastStatusCheck = 0;
			return YES;
		}

		for(PRStatus *s in [DataItem allItemsOfType:@"PRStatus" inMoc:moc])
			[moc deleteObject:s];
	}
	return NO;
}

- (void)fetchPullRequestsForRepos:(NSArray *)repos toMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	if(!repos.count)
	{
		CALLBACK(YES);
		return;
	}
	NSInteger total = repos.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;
	for(Repo *r in repos)
	{
		for(PullRequest *pr in r.pullRequests)
			if(pr.condition.integerValue == kPullRequestConditionOpen)
				pr.postSyncAction = @(kPostSyncDelete);

		[self getPagedDataInPath:[NSString stringWithFormat:@"/repos/%@/pulls",r.fullName]
					  fromServer:r.apiServer
				startingFromPage:1
						  params:nil
					extraHeaders:nil
				 perPageCallback:^BOOL(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 PullRequest *p = [PullRequest pullRequestWithInfo:info fromServer:r.apiServer];
						 p.repo = r;
					 }
					 return NO;
				 } finalCallback:^(BOOL success, NSInteger resultCode, NSString *etag) {
					 r.dirty = @NO;
					 if(success)
					 {
						 succeeded++;
					 }
					 else
					 {
						 if(resultCode == 404) // repo disabled
						 {
							 succeeded++;
							 r.inaccessible = @YES;
							 r.postSyncAction = @(kPostSyncDoNothing);
							 for(PullRequest *p in r.pullRequests)
								 [moc deleteObject:p];
						 }
						 else if(resultCode==410) // repo gone for good
						 {
							 succeeded++;
							 r.postSyncAction = @(kPostSyncDelete);
						 }
						 else
						 {
							 failed++;
						 }
					 }
					 if(succeeded+failed==total)
					 {
						 callback(failed==0);
					 }
				 }];
	}
}

- (void)syncWatchedReposFromServer:(ApiServer *)apiServer andCallback:(void(^)(BOOL success))callback
{
	if(!apiServer.goodToGo)
	{
		CALLBACK(YES); // yes, because there was no fetching failure, we're just ignoring this for now
		return;
	}

	[self getPagedDataInPath:@"/user/subscriptions"
				  fromServer:apiServer
			startingFromPage:1
					  params:nil
				extraHeaders:nil
			 perPageCallback:^BOOL(id data, BOOL lastPage) {
				 for(NSDictionary *info in data)
				 {
                     if([[info ofk:@"private"] boolValue])
                     {
                         NSDictionary *permissions = [info ofk:@"permissions"];
                         if([[permissions ofk:@"pull"] boolValue] ||
                            [[permissions ofk:@"push"] boolValue] ||
                            [[permissions ofk:@"admin"] boolValue])
                         {
                             [Repo repoWithInfo:info fromServer:apiServer];
                         }
                         else
                         {
                             DLog(@"Watched private repository '%@' seems to be inaccessible, skipping",[info ofk:@"full_name"]);
                             continue;
                         }
                     }
                     else
                     {
                         Repo *r = [Repo repoWithInfo:info fromServer:apiServer];
						 r.apiServer = apiServer;
                     }
				 }
				 return NO;
			 } finalCallback:^(BOOL success, NSInteger resultCode, NSString *etag) {
				 if(!success)
				 {
					 DLog(@"Error while fetching data from %@", apiServer.label);
				 }
				 CALLBACK(success);
			 }];
}

- (void)syncUserDetailsInMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	NSArray *allApiServers = [ApiServer allApiServersInMoc:moc];
	__block NSInteger success = 0;
	__block NSInteger fail = 0;
	for(ApiServer *apiServer in allApiServers)
	{
		if(apiServer.goodToGo)
		{
			[self getDataInPath:@"/user"
					 fromServer:apiServer
						 params:nil
				   extraHeaders:nil
					andCallback:^(id data, BOOL lastPage, NSInteger resultCode, NSString *etag) {
						if(data)
						{
							apiServer.userName = [data ofk:@"login"];
							apiServer.userId = [data ofk:@"id"];
							success++;
						}
						else
						{
							DLog(@"Could not read user credentials from %@", apiServer.label);
							fail++;
						}
						if(success+fail==allApiServers.count)
						{
							CALLBACK(fail==0);
						}
					}];
		}
		else
		{
			success++; // yes because there was no fetch failure, we just ignore this
			if(success+fail==allApiServers.count)
			{
				CALLBACK(fail==0);
			}
		}
	}
}

- (void)getPagedDataInPath:(NSString*)path
				fromServer:(ApiServer *)apiServer
		  startingFromPage:(NSInteger)page
					params:(NSDictionary*)params
			  extraHeaders:(NSDictionary *)extraHeaders
		   perPageCallback:(BOOL(^)(id data, BOOL lastPage))pageCallback
			 finalCallback:(void(^)(BOOL success, NSInteger resultCode, NSString *etag))finalCallback
{
	if(!path.length)
	{
		// handling empty or null fields as success, since we don't want syncs to fail, we simply have nothing to process
		dispatch_async(dispatch_get_main_queue(), ^{
			finalCallback(YES, -1, nil);
		});
		return;
	}

	NSMutableDictionary *mparams;
	if(params) mparams = [params mutableCopy];
	else mparams = [NSMutableDictionary dictionaryWithCapacity:2];
	mparams[@"page"] = @(page);
	mparams[@"per_page"] = @100;
	[self getDataInPath:path
			 fromServer:apiServer
				 params:mparams
		   extraHeaders:extraHeaders
			andCallback:^(id data, BOOL lastPage, NSInteger resultCode, NSString *etag) {
				if(data)
				{
					if(pageCallback)
					{
						if(pageCallback(data,lastPage)) lastPage = YES;
					}

					if(lastPage)
					{
						finalCallback(YES, resultCode, etag);
					}
					else
					{
						[self getPagedDataInPath:path
									  fromServer:apiServer
								startingFromPage:page+1
										  params:params
									extraHeaders:extraHeaders
								 perPageCallback:pageCallback
								   finalCallback:finalCallback];
					}
				}
				else
				{
					finalCallback((resultCode==304), resultCode, etag);
				}
			}];
}

- (void)getDataInPath:(NSString*)path
		   fromServer:(ApiServer *)apiServer
			   params:(NSDictionary *)params
		 extraHeaders:(NSDictionary *)extraHeaders
		  andCallback:(void(^)(id data, BOOL lastPage, NSInteger resultCode, NSString *etag))callback
{
	[self get:path
   fromServer:apiServer
   parameters:params
 extraHeaders:extraHeaders
	  success:^(NSHTTPURLResponse *response, id data) {

		  NSDictionary *allHeaders = response.allHeaderFields;

		  apiServer.requestsRemaining = @([allHeaders[@"X-RateLimit-Remaining"] floatValue]);
		  apiServer.requestsLimit = @([allHeaders[@"X-RateLimit-Limit"] floatValue]);
		  float epochSeconds = [allHeaders[@"X-RateLimit-Reset"] floatValue];
		  apiServer.resetDate = [NSDate dateWithTimeIntervalSince1970:epochSeconds];
		  [[NSNotificationCenter defaultCenter] postNotificationName:API_USAGE_UPDATE
															  object:apiServer
															userInfo:nil];
		  CALLBACK(data, [API lastPage:response], response.statusCode, allHeaders[@"Etag"]);
	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  NSInteger code = response.statusCode;
		  if(code==304) DLog(@"No change reported (304)"); else DLog(@"Failure for %@: %@",path,error);
		  CALLBACK(nil, NO, code, nil);
	  }];
}

- (void)getRateLimitFromServer:(ApiServer *)apiServer andCallback:(void (^)(long long, long long, long long))callback
{
	[self get:@"/rate_limit"
   fromServer:apiServer
   parameters:nil
 extraHeaders:nil
	  success:^(NSHTTPURLResponse *response, id data) {
		  long long requestsRemaining = [[response allHeaderFields][@"X-RateLimit-Remaining"] longLongValue];
		  long long requestLimit = [[response allHeaderFields][@"X-RateLimit-Limit"] longLongValue];
		  long long epochSeconds = [[response allHeaderFields][@"X-RateLimit-Reset"] longLongValue];
		  CALLBACK(requestsRemaining,requestLimit,epochSeconds);
	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  if(callback)
		  {
			  if(response.statusCode==404 && data && ![[data ofk:@"message"] isEqualToString:@"Not Found"])
				  callback(10000,10000,0);
			  else
				  callback(-1, -1, -1);
		  }
	  }];
}

- (void)testApiToServer:(ApiServer *)apiServer andCallback:(void (^)(NSError *))callback
{
	[self get:@"/rate_limit"
   fromServer:apiServer
   parameters:nil
 extraHeaders:nil
	  success:^(NSHTTPURLResponse *response, id data) {
		  CALLBACK(nil);
	  } failure:^(NSHTTPURLResponse *response, id data, NSError *error) {
		  if(callback)
		  {
			  if(response.statusCode==404 && data && ![[data ofk:@"message"] isEqualToString:@"Not Found"])
				  callback(nil);
			  else
				  callback(error);
		  }
	  }];
}

+ (BOOL)lastPage:(NSHTTPURLResponse*)response
{
	NSString *linkHeader = [[response allHeaderFields] ofk:@"Link"];
	if(!linkHeader) return YES;
	return ([linkHeader rangeOfString:@"rel=\"next\""].location==NSNotFound);
}

- (NSOperation *)get:(NSString *)path
		  fromServer:(ApiServer *)apiServer
		  parameters:(NSDictionary *)params
		extraHeaders:(NSDictionary *)extraHeaders
			 success:(void(^)(NSHTTPURLResponse *response, id data))successCallback
			 failure:(void(^)(NSHTTPURLResponse *response, id data, NSError *error))failureCallback
{
	[self networkIndicationStart];

	NSString *authToken = apiServer.authToken;
	NSString *apiPath = apiServer.apiPath;

	NSBlockOperation *o = [NSBlockOperation blockOperationWithBlock:^{

		NSString *expandedPath = ([path rangeOfString:@"/"].location==0) ? [apiPath stringByAppendingPathComponent:path] : path;

		if(params.count)
		{
			expandedPath = [expandedPath stringByAppendingString:@"?"];
			NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:params.count];
			for(NSString *key in params)
			{
				[pairs addObject:[NSString stringWithFormat:@"%@=%@", key, params[key]]];
			}
			expandedPath = [expandedPath stringByAppendingString:[pairs componentsJoinedByString:@"&"]];
		}

		NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:expandedPath]
															  cachePolicy:NSURLRequestUseProtocolCachePolicy
														  timeoutInterval:NETWORK_TIMEOUT];

		[r setValue:[self userAgent] forHTTPHeaderField:@"User-Agent"];

		[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

		if(authToken) [r setValue:[@"token " stringByAppendingString:authToken] forHTTPHeaderField:@"Authorization"];

		for(NSString *extraHeaderKey in extraHeaders)
		{
			DLog(@"Custom header: %@=%@",extraHeaderKey,extraHeaders[extraHeaderKey]);
			[r setValue:extraHeaders[extraHeaderKey] forHTTPHeaderField:extraHeaderKey];
		}

		////////////////////////// preempt with error backoff algorithm
		NSString *fullUrlPath = r.URL.absoluteString;
		UrlBackOffEntry *existingBackOff = badLinks[fullUrlPath];
		if(existingBackOff)
		{
			if([[NSDate date] compare:existingBackOff.nextAttemptAt]==NSOrderedAscending)
			{
				// report failure and return
				DLog(@"Preempted fetch to previously broken link %@, won't actually access this URL until %@", fullUrlPath, existingBackOff.nextAttemptAt);
				if(failureCallback)
				{
					NSError *error = [NSError errorWithDomain:@"Preempted fetch because of throttling" code:400 userInfo:nil];
					dispatch_async(dispatch_get_main_queue(), ^{
						failureCallback(nil, nil, error);
					});
				}
				[self networkIndicationEnd];
				return;
			}
		}

#ifdef DEBUG
		NSDate *startTime = [NSDate date];
#endif

		NSError *error;
		NSHTTPURLResponse *response;
		NSData *data = [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];

#ifdef DEBUG
		NSTimeInterval networkTime = [[NSDate date] timeIntervalSinceDate:startTime];
#endif

		id parsedData = nil;
		if(data.length) parsedData = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];

		if(!error && response.statusCode>299)
		{
			error = [NSError errorWithDomain:@"Error response received" code:response.statusCode userInfo:nil];
			if(response.statusCode>=400)
			{
				if(existingBackOff)
				{
					DLog(@"Extending backoff for already throttled URL %@ by %f seconds", fullUrlPath, BACKOFF_STEP);
					if(existingBackOff.duration<3600.0) existingBackOff.duration += BACKOFF_STEP;
					existingBackOff.nextAttemptAt = [NSDate dateWithTimeInterval:existingBackOff.duration sinceDate:[NSDate date]];
				}
				else
				{
					DLog(@"Placing URL %@ on the throttled list", fullUrlPath);
					UrlBackOffEntry *newBackOff = [[UrlBackOffEntry alloc] init];
					newBackOff.duration = existingBackOff.duration+BACKOFF_STEP;
					newBackOff.nextAttemptAt = [NSDate dateWithTimeInterval:newBackOff.duration sinceDate:[NSDate date]];
					badLinks[fullUrlPath] = newBackOff;
				}
			}
		}

		if(error)
		{
			DLog(@"GET %@ - FAILED: %@", fullUrlPath, error.localizedDescription);
			if(failureCallback)
			{
				dispatch_async(dispatch_get_main_queue(), ^{
					failureCallback(response, parsedData, error);
				});
			}
		}
		else
		{
#ifdef DEBUG
			DLog(@"GET %@ - RESULT: %ld, %f sec.", fullUrlPath, (long)response.statusCode, networkTime);
#else
			DLog(@"GET %@ - RESULT: %ld", fullUrlPath, (long)response.statusCode);
#endif
			[badLinks removeObjectForKey:fullUrlPath];
			if(successCallback)
			{
				dispatch_async(dispatch_get_main_queue(), ^{
					successCallback(response, parsedData);
				});
			}
		}

		[self networkIndicationEnd];
	}];
	o.queuePriority = NSOperationQueuePriorityVeryHigh;
	[requestQueue addOperation:o];
	return o;
}

// warning: now calls back on thread!!
- (NSOperation *)getImage:(NSURL *)url
				  success:(void(^)(NSHTTPURLResponse *response, NSData *imageData))successCallback
				  failure:(void(^)(NSHTTPURLResponse *response, NSError *error))failureCallback
{
	double delayInSeconds = 0.5;
	dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
		[self networkIndicationStart];
	});

	NSBlockOperation *o = [NSBlockOperation blockOperationWithBlock:^{

		NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:url
															  cachePolicy:NSURLRequestUseProtocolCachePolicy
														  timeoutInterval:NETWORK_TIMEOUT];
		[r setValue:[self userAgent] forHTTPHeaderField:@"User-Agent"];

		NSError *error;
		NSHTTPURLResponse *response;
		NSData *data = [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];
		if(!error && response.statusCode>299)
		{
			error = [NSError errorWithDomain:@"Error response received" code:response.statusCode userInfo:nil];
		}
		if(error)
		{
			//DLog(@"IMAGE %@ - FAILED: %@",path,error);
			if(failureCallback)
			{
                failureCallback(response, error);
			}
		}
		else
		{
			//DLog(@"IMAGE %@ - RESULT: %ld",path,(long)response.statusCode);
			if(successCallback)
			{
				if(data.length)
				{
                    successCallback(response, data);
				}
				else
				{
                    failureCallback(response, error);
				}
			}
		}

		[self networkIndicationEnd];
	}];
	o.queuePriority = NSOperationQueuePriorityVeryLow;
	[requestQueue addOperation:o];
	return o;
}

- (NSString *)userAgent
{
#ifdef DEBUG
	#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
		return [NSString stringWithFormat:@"HouseTrip-Trailer-v%@-iOS-Development",app.currentAppVersion];
	#else
		return [NSString stringWithFormat:@"HouseTrip-Trailer-v%@-OSX-Development",app.currentAppVersion];
	#endif
#else
	#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
		return [NSString stringWithFormat:@"HouseTrip-Trailer-v%@-iOS-Release",app.currentAppVersion];
	#else
		return [NSString stringWithFormat:@"HouseTrip-Trailer-v%@-OSX-Release",app.currentAppVersion];
	#endif
#endif
}

- (void)networkIndicationStart
{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	dispatch_async(dispatch_get_main_queue(), ^{
		if(++networkIndicationCount==1)
			[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	});
#endif
}

- (void)networkIndicationEnd
{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	dispatch_async(dispatch_get_main_queue(), ^{
		if(--networkIndicationCount==0)
			[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
	});
#endif
}

- (void)clearImageCache
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:nil];
    for(NSString *f in files)
    {
        if([f rangeOfString:@"imgcache-"].location==0)
        {
            NSString *path = [cacheDirectory stringByAppendingPathComponent:f];
            [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (void)expireOldImageCacheEntries
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:nil];
    for(NSString *f in files)
    {
        NSDate *now = [NSDate date];
        if([f rangeOfString:@"imgcache-"].location==0)
        {
            NSString *path = [cacheDirectory stringByAppendingPathComponent:f];
            NSError *error;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
            NSDate *date = attributes[NSFileCreationDate];
            if([now timeIntervalSinceDate:date]>(3600.0*24))
                [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (BOOL)haveCachedAvatar:(NSString *)path
	  tryLoadAndCallback:(void (^)(IMAGE_CLASS *image))callbackOrNil
{
	NSURLComponents *c = [NSURLComponents componentsWithString:path];
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	c.query = [NSString stringWithFormat:@"s=%.0f",40.0*GLOBAL_SCREEN_SCALE];
#else
	c.query = [NSString stringWithFormat:@"s=%.0f",88.0];
#endif
	NSURL *imageURL = c.URL;
    NSString *imageKey = [NSString stringWithFormat:@"%@ %@",
						  imageURL.absoluteString,
						  app.currentAppVersion];

    NSString *cachePath = [cacheDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"imgcache-%@", [imageKey md5hash]]];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if([fileManager fileExistsAtPath:cachePath])
    {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
		CFDataRef imgData = (__bridge CFDataRef)[NSData dataWithContentsOfFile:cachePath];
		CGDataProviderRef imgDataProvider = CGDataProviderCreateWithCFData (imgData);
		CGImageRef cfImage = CGImageCreateWithJPEGDataProvider(imgDataProvider, NULL, false, kCGRenderingIntentDefault);
		CGDataProviderRelease(imgDataProvider);

		UIImage *ret = [[UIImage alloc] initWithCGImage:cfImage
												  scale:GLOBAL_SCREEN_SCALE
											orientation:UIImageOrientationUp];
		CGImageRelease(cfImage);
#else
        NSImage *ret = [[NSImage alloc] initWithContentsOfFile:cachePath];
#endif
        if(ret)
        {
            if(callbackOrNil) callbackOrNil(ret);
            return YES;
        }
        else
        {
            [fileManager removeItemAtPath:cachePath error:nil];
        }
    }

    if(callbackOrNil)
    {
        [self getImage:imageURL
               success:^(NSHTTPURLResponse *response, NSData *imageData) {
                   id image = nil;
                   if(imageData)
                   {
					   @autoreleasepool
					   {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
						   image = [UIImage imageWithData:imageData scale:GLOBAL_SCREEN_SCALE];
						   [UIImageJPEGRepresentation(image, 1.0) writeToFile:cachePath atomically:YES];
#else
						   image = [[NSImage alloc] initWithData:imageData];
						   [[image TIFFRepresentation] writeToFile:cachePath atomically:YES];
#endif
					   }
                   }
                   dispatch_async(dispatch_get_main_queue(), ^{
                       callbackOrNil(image);
                   });
               } failure:^(NSHTTPURLResponse *response, NSError *error) {
                   dispatch_async(dispatch_get_main_queue(), ^{
                       callbackOrNil(nil);
                   });
               }];
    }

    return NO;
}

- (NSString *)lastUpdateDescription
{
	if(app.isRefreshing)
	{
		return @"Refreshing...";
	}
	else if(app.lastUpdateFailed)
	{
		return @"Last update failed";
	}
	else
	{
		NSDate *lastSuccess = app.lastSuccessfulRefresh;
		if(!lastSuccess) lastSuccess = [NSDate date];
		long ago = (long)[[NSDate date] timeIntervalSinceDate:lastSuccess];
		if(ago<10)
			return @"Just updated";
		else
			return [NSString stringWithFormat:@"Updated %ld seconds ago",(long)ago];
	}
	
}

@end
