#import <CoreData/CoreData.h>
#import "AppDelegate.h"
#import "ChatStore.h"
#import "CreateRideViewController.h"
#import "MyRidesViewController.h"
#import "Notification.h"

@interface MyRidesViewController () <CreateRideDelegate, RideDelegate>
@property (nonatomic) NSManagedObjectContext *managedObjectContext;
@property (nonatomic) NSArray<Notification *> *unreadNotifications;
@end

@implementation MyRidesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.navigationItem.titleView = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"NavigationBarLogo"]];
    
    AppDelegate *appDelegate = [UIApplication sharedApplication].delegate;
    self.managedObjectContext = appDelegate.managedObjectContext;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didUpdateNotifications:) name:CaronaeDidUpdateNotifications object:nil];
    
    [self updateUnreadNotifications];
    [self loadMyRides];
}

- (void)refreshTable:(id)sender {
    if (self.refreshControl.refreshing) {
        [self loadMyRides];
    }
}


#pragma mark - Ride methods

- (void)loadMyRides {
    if (self.tableView.backgroundView != nil) {
        self.tableView.backgroundView = self.loadingLabel;
    }
    
    User *user = [CaronaeDefaults defaults].user;
    
    // Run in secondary thread so it won't affect UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSArray *ridesJSON = [[NSUserDefaults standardUserDefaults] objectForKey:@"userCreatedRides"];
        NSError *error;
        NSArray<Ride *> *rideArchive = [MTLJSONAdapter modelsOfClass:Ride.class fromJSONArray:ridesJSON error:&error];
        if (error) {
            NSLog(@"Error parsing my rides. %@", error.localizedDescription);
            [self loadingFailedWithOperation:nil error:error];
            return;
        }
        
        NSMutableArray *rides = [[NSMutableArray alloc] initWithCapacity:rideArchive.count];
        for (Ride *ride in rideArchive) {
            ride.driver = user;
            
            // Checking if subscribed to my rides after delay to ensure GCM is connected
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                if (![ChatStore chatForRide:ride]) {
                    Chat *chat = [[Chat alloc] initWithRide:ride];
                    if (!chat.subscribed) {
                        [chat subscribe];
                    }
                    [ChatStore setChat:chat forRide:ride];
                }
            });

            [rides addObject:ride];
        }
        
        NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"date" ascending:YES];
        self.rides = [rides sortedArrayUsingDescriptors:@[sortDescriptor]];
        
        if (self.rides.count > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.refreshControl endRefreshing];
                self.tableView.backgroundView = nil;
                [self.tableView reloadData];
            });
        }
        else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.refreshControl endRefreshing];
                self.tableView.backgroundView = self.emptyTableLabel;
            });
        }
    });
}

- (void)didCreateRides:(NSArray<NSDictionary *> *)rides {
    NSLog(@"%lu rides created.", (unsigned long)rides.count);
    
    NSArray *oldUserRidesArchive = [[NSUserDefaults standardUserDefaults] arrayForKey:@"userCreatedRides"];
    NSMutableArray *newUserRidesArchive = [NSMutableArray arrayWithArray:oldUserRidesArchive];
    NSError *error;
    NSArray *createdRidesJSON = [MTLJSONAdapter JSONArrayFromModels:rides error:&error];
    if (error) {
        NSLog(@"Error serializing created rides. %@", error.localizedDescription);
        return;
    }
    
    [newUserRidesArchive addObjectsFromArray:createdRidesJSON];
    
    [[NSUserDefaults standardUserDefaults] setObject:newUserRidesArchive forKey:@"userCreatedRides"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [self loadMyRides];
}

- (void)didDeleteRide:(Ride *)ride {
    NSLog(@"User has deleted ride with id %ld", ride.rideID);
    
    [self removeRideFromMyRides:ride];
    [self loadMyRides];
}

- (void)didFinishRide:(Ride *)ride {
    NSLog(@"User has finished ride with id %ld", ride.rideID);
    
    [self removeRideFromMyRides:ride];
    [self loadMyRides];
}

- (void)removeRideFromMyRides:(Ride *)ride {
    // Find and delete ride from persistent store
    NSMutableArray *newRides = [[[NSUserDefaults standardUserDefaults] objectForKey:@"userCreatedRides"] mutableCopy];
    for (NSDictionary *r in newRides) {
        if ([r[@"rideId"] longValue] == ride.rideID || [r[@"id"] longValue] == ride.rideID) {
            [newRides removeObject:r];
            break;
        }
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:newRides forKey:@"userCreatedRides"];
    
    if (![self.rides containsObject:ride]) {
        NSLog(@"Error: ride to be deleted was not found in user's rides");
        return;
    }
}


#pragma mark - Table methods

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    RideCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    
    int unreadCount = 0;
    Ride *ride = self.filteredRides[indexPath.row];
    NSNumber *rideID = @(ride.rideID);
    for (Notification *caronaeNotification in self.unreadNotifications) {
        if ([caronaeNotification.rideID isEqualToNumber:rideID]) {
            ++unreadCount;
        }
    }
    
    cell.badgeCount = unreadCount;
    
    return cell;
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"CreateRide"]) {
        UINavigationController *navigationVC = segue.destinationViewController;
        CreateRideViewController *vc = (CreateRideViewController *)navigationVC.topViewController;
        vc.delegate = self;
    }
}


#pragma mark - Notification handling

- (void)updateUnreadNotifications {
    NSFetchRequest *fetchRequest = [[NSFetchRequest alloc] init];
    NSEntityDescription *entity = [NSEntityDescription entityForName:NSStringFromClass(Notification.class) inManagedObjectContext:self.managedObjectContext];
    fetchRequest.entity = entity;
    fetchRequest.includesPropertyValues = NO;
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"type == 'joinRequest'"];
    fetchRequest.predicate = predicate;
    
    NSError *error;
    self.unreadNotifications = [self.managedObjectContext executeFetchRequest:fetchRequest error:&error];
    if (error) {
        NSLog(@"Whoops, couldn't load unread notifications: %@", error.localizedDescription);
        return;
    }
    
    if (self.unreadNotifications.count > 0) {
        self.navigationController.tabBarItem.badgeValue = [NSString stringWithFormat:@"%ld", (long)self.unreadNotifications.count];
    }
    else {
        self.navigationController.tabBarItem.badgeValue = nil;
    }
}

- (void)didUpdateNotifications:(NSNotification *)notification {
    NSString *msgType = notification.userInfo[@"msgType"];
    
    if ([msgType isEqualToString:@"joinRequest"]) {
        [self updateUnreadNotifications];
        [self.tableView reloadData];
    }
}


@end