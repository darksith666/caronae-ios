#import <UIKit/UIKit.h>
#import "RideListController.h"

@interface SearchResultsViewController : RideListController

- (void)searchForRidesWithParameters:(NSDictionary *)params;

@end