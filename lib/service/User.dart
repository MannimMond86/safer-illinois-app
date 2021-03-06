/*
 * Copyright 2020 Board of Trustees of the University of Illinois.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:convert';

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';
import 'package:illinois/model/UserData.dart';
import 'package:illinois/service/AppLivecycle.dart';
import 'package:illinois/service/Auth.dart';
import 'package:illinois/service/Config.dart';
import 'package:illinois/service/FirebaseMessaging.dart';
import 'package:illinois/service/Log.dart';
import 'package:illinois/service/NotificationService.dart';
import 'package:illinois/service/Service.dart';
import 'package:illinois/service/Storage.dart';
import 'package:illinois/service/Network.dart';
import 'package:illinois/utils/Utils.dart';
import 'package:http/http.dart' as http;

class User with Service implements NotificationsListener {

  static const String notifyUserUpdated = "edu.illinois.rokwire.user.updated";
  static const String notifyUserDeleted = "edu.illinois.rokwire.user.deleted";
  static const String notifyTagsUpdated  = "edu.illinois.rokwire.user.tags.updated";
  static const String notifyRolesUpdated  = "edu.illinois.rokwire.user.roles.updated";
  static const String notifyFavoritesUpdated  = "edu.illinois.rokwire.user.favorites.updated";
  static const String notifyInterestsUpdated  = "edu.illinois.rokwire.user.interests.updated";

  static final String sportsInterestCategory = "sports";

  UserData _userData;

  http.Client _client = http.Client();

  static final User _service = new User._internal();

  factory User() {
    return _service;
  }

  User._internal();

  @override
  void createService() {
    NotificationService().subscribe(this, [
      AppLivecycle.notifyStateChanged,
      FirebaseMessaging.notifyToken,
    ]);
  }

  @override
  void destroyService() {
    NotificationService().unsubscribe(this);
  }

  @override
  Future<void> initService() async {

    _userData = Storage().userData;
    
    if (_userData == null) {
      await _createUser();
    } else if (_userData.uuid != null) {
      await _loadUser();
    }
  }

  Set<Service> get serviceDependsOn {
    return Set.from([Storage(), Config()]);
  }

  // NotificationsListener
  @override
  void onNotification(String name, dynamic param) {
    if (name == FirebaseMessaging.notifyToken) {
      _updateFCMToken();
    }
    else if(name == AppLivecycle.notifyStateChanged && param == AppLifecycleState.resumed){
      //_loadUser();
    }
  }

  // User

  String get uuid {
    return _userData?.uuid;
  }
  
  UserData get data {
    return _userData;
  }

  static String get analyticsUuid {
    return UserData.analyticsUuid;
  }

  Future<void> _createUser() async {  
    UserData userData = await _requestCreateUser();
    applyUserData(userData);
    Storage().localUserUuid = userData?.uuid;
  }

  Future<void> _loadUser() async {
    // silently refresh user profile
    requestUser(_userData.uuid).then((UserData userData) {
      if (userData != null) {
        applyUserData(userData, applyCachedSettings: true);
      }
    })
    .catchError((_){
        _clearStoredUserData();
      }, test: (error){return error is UserNotFoundException;});
  }

  Future<void> _updateUser() async {

    if (_userData == null) {
      return;
    }

    // Stop previous request
    if (_client != null) {
      _client.close();
    }

    http.Client client;
    _client = client = http.Client();

    String userUuid = _userData.uuid;
    String url = (Config().userProfileUrl != null) ? "${Config().userProfileUrl}/$userUuid" : null;
    Map<String, String> headers = {"Accept": "application/json","content-type":"application/json"};
    final response = await Network().put(url, body: json.encode(_userData.toJson()), headers: headers, client: _client, auth: NetworkAuth.App);
    String responseBody = response?.body;
    bool success = ((response != null) && (responseBody != null) && (response.statusCode == 200));
    
    if (!success) {
      //error
      String message = "Error on updating user - " + (response != null ? response.statusCode.toString() : "null");
      Crashlytics().log(message);
    }
    else if (_client == client) {
      _client = null;
      Map<String, dynamic> jsonData = AppJson.decode(responseBody);
      UserData update = UserData.fromJson(jsonData);
      if (update != null) {
        Storage().userData = _userData = update;
        //_notifyUserUpdated();
      }
    }
    else {
      Log.d("Updating user canceled");
    }

  }

  Future<UserData> requestUser(String uuid) async {
    String url = ((Config().userProfileUrl != null) && (uuid != null) && (0 < uuid.length)) ? '${Config().userProfileUrl}/$uuid' : null;

    final response = await Network().get(url, auth: NetworkAuth.App);

    if(response != null) {
      if (response?.statusCode == 404) {
        throw UserNotFoundException();
      }

      String responseBody = ((response != null) && (response?.statusCode == 200)) ? response?.body : null;
      Map<String, dynamic> jsonData = AppJson.decode(responseBody);
      if (jsonData != null) {
        return UserData.fromJson(jsonData);
      }
    }

    return null;
  }

  Future<UserData> _requestCreateUser() async {
    try {
      final response = await Network().post(Config().userProfileUrl, auth: NetworkAuth.App, timeout: 10);
      if ((response != null) && (response.statusCode == 200)) {
        String responseBody = response.body;
        Map<String, dynamic> jsonData = AppJson.decode(responseBody);
        return UserData.fromJson(jsonData);
      } else {
        return null;
      }
    } catch(e){
      Log.e('Failed to create user');
      Log.e(e.toString());
      return null;
    }
  }

  Future<void> deleteUser() async{
    String userUuid = _userData?.uuid;
    if((Config().userProfileUrl != null) && (userUuid != null)) {
      await Network().delete("${Config().userProfileUrl}/$userUuid", headers: {"Accept": "application/json", "content-type": "application/json"}, auth: NetworkAuth.App);

      _clearStoredUserData();
      _notifyUserDeleted();

      try {
        _userData = await requestUser(Storage().localUserUuid);
      } on UserNotFoundException catch (_) {
        _userData = await _requestCreateUser();
        if (_userData?.uuid != null) {
          Storage().localUserUuid = _userData?.uuid;
        }
      }
      if (_userData != null) {
        Storage().userData = _userData;
        _notifyUserUpdated();
      }
    }

  }

  void initLocalUser() {
    String localUserUuid = Storage().localUserUuid;
    String currentUserUuid = _userData?.uuid;
    if ((localUserUuid != null) && (currentUserUuid == null) || (currentUserUuid != localUserUuid)) {
      requestUser(localUserUuid).then((UserData userData){
        if (userData != null) {
          applyUserData(userData);
        }
        //clearStoredPiiAccount();
      }).catchError((_){
      });
    }
  }

  void applyUserData(UserData userData, { bool applyCachedSettings = false }) {
    
    // 1. We might need to remove FCM token from current user
    String applyUserUuid = userData?.uuid;
    String currentUserUuid = _userData?.uuid;
    bool userSwitched = (currentUserUuid != null) && (currentUserUuid != applyUserUuid);
    if (userSwitched && _removeFCMToken(_userData)) {
      String url = "${Config().userProfileUrl}/${_userData.uuid}";
      Map<String, String> headers = {"Accept": "application/json","content-type":"application/json"};
      String post = json.encode(_userData.toJson());
      Network().put(url, body: post, headers: headers, auth: NetworkAuth.App);
    }

    // 2. We might need to add FCM token and user roles from Storage to new user
    bool applyUserUpdated = _applyFCMToken(userData);
    if (applyCachedSettings) {
      applyUserUpdated = _updateUserSettingsFromStorage(userData) || applyUserUpdated;
    }

    _userData = userData;
    Storage().userData = _userData;
    Storage().userRoles = userData?.roles;

    if (userSwitched) {
      _notifyUserUpdated();
    }
    
    if (applyUserUpdated) {
      _updateUser();
    }
  }

  void _clearStoredUserData(){
    _userData = null;
    Storage().userData = null;
    Auth().logout();
    Storage().onBoardingPassed = false;
  }

  // FCM Tokens

  void _updateFCMToken() {
    if (_applyFCMToken(_userData)) {
      _updateUser();
    }
  }

  static bool _applyFCMToken(UserData userData) {
    String fcmToken = FirebaseMessaging().token;
    if ((userData != null) && (fcmToken != null)) {
      if (userData.fcmTokens == null) {
        userData.fcmTokens = Set.from([fcmToken]);
        return true;
      }
      else if (!userData.fcmTokens.contains(fcmToken)) {
        userData.fcmTokens.add(fcmToken);
        return true;
      }
    }
    return false;
  }

  static bool _removeFCMToken(UserData userData) {
    String fcmToken = FirebaseMessaging().token;
    if ((userData != null) && (userData.fcmTokens != null) && (fcmToken != null) && userData.fcmTokens.contains(fcmToken)) {
      userData.fcmTokens.remove(fcmToken);
      return true;
    }
    return false;
  }

  // Backward compatability + stability (use last stored roles & privacy if they are missing)
  static bool _updateUserSettingsFromStorage(UserData userData) {
    bool userUpdated = false;

    if (userData != null) {
      if (userData.roles == null) {
        userData.roles = Storage().userRoles;
        userUpdated = userUpdated || (userData.roles != null);
      }
    }

    return userUpdated;
  }

  // Privacy

  int get privacyLevel {
    return _userData?.privacyLevel ?? UserData.PrivacyLevel;
  }

  bool privacyMatch(int requredPrivacyLevel) {
    return (this.privacyLevel >= requredPrivacyLevel);
  }

  bool get favoritesStarVisible {
    return privacyMatch(2);
  }

  bool get showTicketsConfirmationModal {
    return !privacyMatch(4);
  }

  //Favorites
  void switchFavorite(Favorite favorite) {
    if(isFavorite(favorite))
      removeFavorite(favorite);
    else
      addFavorite(favorite);
  }

  void addFavorite(Favorite favorite) {
    if(favorite==null || _userData==null)
      return;

    if(AppString.isStringNotEmpty(favorite.favoriteId)) {
      _userData.addFavorite(favorite.favoriteKey,favorite.favoriteId);
      _notifyUserFavoritesUpdated();
      _updateUser().then((_) {
        _notifyUserFavoritesUpdated();
      });
    }
  }

  void addAllFavorites(List<Favorite> favorites) {
    if ((_userData == null) || AppCollection.isCollectionEmpty(favorites)) {
      return;
    }
    String favoriteKey = favorites.first?.favoriteKey;
    Set<String> uiuds = favorites.map(((value) => value.favoriteId)).toSet();
    _userData.addAllFavorites(favoriteKey, uiuds);
    _notifyUserFavoritesUpdated();
    _updateUser().then((_) {
      _notifyUserFavoritesUpdated();
    });
  }

  void removeFavorite(Favorite favorite) {
    if(favorite==null || _userData==null)
      return;

    if(AppString.isStringNotEmpty(favorite.favoriteId)) {
      _userData.removeFavorite(favorite.favoriteKey,favorite.favoriteId);
      _notifyUserFavoritesUpdated();
      _updateUser().then((_) {
        _notifyUserFavoritesUpdated();
      });
    }
  }

  void removeAllFavorites(List<Favorite> favorites) {
    if ((_userData == null) || AppCollection.isCollectionEmpty(favorites)) {
      return;
    }
    String favoriteKey = favorites.first?.favoriteKey;
    Set<String> uiuds = favorites.map(((value) => value.favoriteId)).toSet();
    _userData.removeAllFavorites(favoriteKey, uiuds);
    _notifyUserFavoritesUpdated();
    _updateUser().then((_) {
      _notifyUserFavoritesUpdated();
    });
  }


  bool isFavorite(Favorite favorite) {
    return _userData?.isFavorite(favorite) ?? false;
  }

  Set<String> getFavorites(String favoriteKey) {
      return _userData?.getFavorites(favoriteKey);
  }

  //Sport categories (Interest)
  switchInterestCategory(String categoryName) async{
    _userData?.switchCategory(categoryName);

    _updateUser().then((_){
      _notifyUserInterestsUpdated();
    });
  }

  switchSportSubCategory(String sportSubCategory) async {
    if(_userData!=null){
      _userData.switchInterestSubCategory(sportsInterestCategory, sportSubCategory);
       // the ui should be updated immediately
      _notifyUserInterestsUpdated();
    }

    _updateUser().then((_){
      _notifyUserInterestsUpdated();
    });
  }

  switchSportSubCategories(List<String> sportSubCategories) async {
    if (sportSubCategories == null || sportSubCategories.isEmpty) {
      return;
    }
    if (_userData != null) {
      for (String category in sportSubCategories) {
        _userData.switchInterestSubCategory(sportsInterestCategory, category);
      }
      _notifyUserInterestsUpdated();
      _updateUser().then((_) {
        _notifyUserInterestsUpdated();
      });
    }
  }

  List<String> getSportsInterestSubCategories() {
    return  _userData?.interests!=null?_userData?.interests[sportsInterestCategory] : null;
  }

  Map<String,List<String>> getInterests() {
    return _userData?.interests;
  }

  List<String> getInterestsCategories() {
    if(_userData!=null && _userData.interests!=null){
      return _userData.interests.keys.toList();
    } else {
      return null;
    }
  }

  ///////
  //Tags
  List<String> getTags() {
    return _userData?.positiveTags;
  }

  switchTag(String tag,{bool fastRefresh=true}) {
    bool positiveInterest = true;
    if(isTagged(tag,positiveInterest)){
      removeTag(tag,fastRefresh);
    } else {
      addTag(tag, positiveInterest,fastRefresh);
    }
  }

  addTag(String tag, bool positiveInterest, bool fastRefresh) {
    if(tag==null || _userData==null)
      return;

    if(AppString.isStringNotEmpty(tag)) {
      if(positiveInterest){
        _userData.addPositiveTag(tag);
      } else {
        _userData.addNegativeTag(tag);
      }
      if(fastRefresh)
        _notifyUserTagsUpdated();
      _updateUser().then((_) {
        _notifyUserTagsUpdated();
      });
    }
  }

  removeTag(String tag,bool fastRefresh) {
    if(tag==null || _userData==null)
      return;

    if(AppString.isStringNotEmpty(tag)) {
      _userData.removeTag(tag);
      if(fastRefresh)
        _notifyUserTagsUpdated();
      _updateUser().then((_) {
        _notifyUserTagsUpdated();
      });
    }
  }

  bool isTagged(String tag, bool positiveInterest) {
    return _userData?.containsTag(tag) ?? false;
  }

  //UserRoles
  Set<UserRole> get roles {
    return _userData?.roles;
  }

  set roles(Set<UserRole> userRoles) {
    if (_userData != null) {
      _userData.roles = userRoles;
      Storage().userData = _userData;
      Storage().userRoles = userRoles;
      _updateUser().then((_){
        _notifyUserRolesUpdated();
      });
    }
  }

  bool rolesMatch(List<UserRole> permittedRoles) {
    Set<UserRole> currentUserRoles = roles;
    if (!AppCollection.isCollectionNotEmpty(permittedRoles) || (currentUserRoles == null)) {
      return true; //default
    }

    for (UserRole role in permittedRoles) {
      if (currentUserRoles?.contains(role) ?? false) {
        return true;
      }
    }

    return false;
  }

  bool get isResident{
    return AppCollection.isCollectionNotEmpty(roles) ? roles.contains(UserRole.resident) : false;
  }

  bool get isStudentOrEmployee {
    if (AppCollection.isCollectionEmpty(roles)) {
      return false;
    }
    return roles.contains(UserRole.student) || roles.contains(UserRole.employee);
  }

  // Notifications

  void _notifyUserUpdated() {
    NotificationService().notify(notifyUserUpdated, null);
  }

  void _notifyUserDeleted() {
    NotificationService().notify(notifyUserDeleted, null);
  }

  void _notifyUserRolesUpdated() {
    NotificationService().notify(notifyRolesUpdated, null);
  }

  void _notifyUserInterestsUpdated() {
    NotificationService().notify(notifyInterestsUpdated, null);
  }

  void _notifyUserFavoritesUpdated(){
    NotificationService().notify(notifyFavoritesUpdated, null);
  }

  void _notifyUserTagsUpdated() {
    NotificationService().notify(notifyTagsUpdated, null);
  }
}

class UserNotFoundException implements Exception{
  final String message;
  UserNotFoundException({this.message});

  @override
  String toString() {
    return message;
  }
}