// Copyright (c) 2021, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/log;
import ballerinax/googleapis.gmail as gmail;

# Listener for Gmail Connector.
@display {label: "Gmail Listener", iconPath: "resources/googleapis.gmail.svg"}
public class Listener {
    private string startHistoryId = "";
    private string topicResource = "";
    private string subscriptionResource = "";
    private string userId = ME;
    private gmail:ConnectionConfig gmailConfig;
    private http:Listener httpListener;
    private string project;
    private string pushEndpoint;

    private WatchRequestBody requestBody = {topicName: ""};
    private HttpService? httpService;
    http:Client pubSubClient;
    http:Client gmailHttpClient;

    # Initializes the Gmail connector listener.
    #
    # + port - Port number to initiate the listener
    # + gmailConfig - Configurations required to initialize the `gmail:Client` endpoint
    # + project - The id of the project which is created in `Google Cloud Platform`  to create credentials
    # + pushEndpoint - The endpoint URL of the listener
    # + listenerConfig - Configurations required to initialize the `Listener` endpoint with service account
    # + return - Error if any failures during initialization.
    public isolated function init(int port, gmail:ConnectionConfig gmailConfig, string project, string pushEndpoint,
                                    GmailListenerConfiguration? listenerConfig = ()) returns @tainted error? {

        http:ClientSecureSocket? socketConfig = (listenerConfig is GmailListenerConfiguration) ? (listenerConfig
                                                    ?.secureSocketConfig) : (gmailConfig.secureSocket);
        // Create pubsub http client.
        self.pubSubClient = check new (PUBSUB_BASE_URL, {
            auth: (listenerConfig is GmailListenerConfiguration) ? (listenerConfig.authConfig) 
                    : (gmailConfig.auth),
            secureSocket: socketConfig
        });
        // Create gmail http client.
        self.gmailHttpClient = check new (gmail:BASE_URL, gmailConfig);

        self.httpListener = check new (port);
        self.gmailConfig = gmailConfig;
        self.project = project;
        self.pushEndpoint = pushEndpoint;

        TopicSubscriptionDetail topicSubscriptionDetail = check createTopic(self.pubSubClient, project, pushEndpoint);
        self.topicResource = topicSubscriptionDetail.topicResource;
        self.subscriptionResource = topicSubscriptionDetail.subscriptionResource;
        self.requestBody = {topicName: self.topicResource, labelIds: [INBOX], labelFilterAction: INCLUDE};

        self.httpService = ();
    }

    public isolated function attach(SimpleHttpService s, string[]|string? name = ()) returns @tainted error? {
        HttpToGmailAdaptor adaptor = check new (s);
        HttpService currentHttpService = new (adaptor, self.gmailConfig, self.startHistoryId,
                                              self.subscriptionResource);
        self.httpService = currentHttpService;
        check self.watchMailbox();
        check self.httpListener.attach(currentHttpService, name);
        Job job = new (self);
        check job.scheduleNextWatchRenewal();
    }

    public isolated function detach(SimpleHttpService s) returns error? {
        HttpService? currentHttpService = self.httpService;
        if currentHttpService is HttpService {
            return self.httpListener.detach(currentHttpService);
        }        
    }

    public isolated function 'start() returns error? {
        return self.httpListener.'start();
    }

    public isolated function gracefulStop() returns @tainted error? {
        _ = check deletePubsubSubscription(self.pubSubClient, self.subscriptionResource);
        _ = check deletePubsubTopic(self.pubSubClient, self.topicResource);
        var response = check stop(self.gmailHttpClient, self.userId);
        log:printInfo(WATCH_STOPPED + response.toString());
        return self.httpListener.gracefulStop();
    }

    public isolated function immediateStop() returns error? {
        return self.httpListener.immediateStop();
    }

    public isolated function watchMailbox() returns @tainted error? {
        WatchResponse response = check watch(self.gmailHttpClient, self.userId, self.requestBody);
        self.startHistoryId = response.historyId;
        log:printInfo(NEW_HISTORY_ID + self.startHistoryId);
        HttpService? httpService = self.httpService;
        if (httpService is HttpService) {
            httpService.setStartHistoryId(self.startHistoryId);
        }
    }
}

# Holds the parameters used to create a `Listener`.
#
# + authConfig - Auth client configuration
# + secureSocketConfig - Secure socket configuration
@display {label: "Listener Connection Config"}
public type GmailListenerConfiguration record {
    @display {label: "Auth Config"}
    http:JwtIssuerConfig authConfig;
    @display {label: "SSL Config"}
    http:ClientSecureSocket secureSocketConfig?;
};
