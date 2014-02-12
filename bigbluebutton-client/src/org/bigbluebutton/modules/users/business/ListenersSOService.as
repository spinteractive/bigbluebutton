/**
 * BigBlueButton open source conferencing system - http://www.bigbluebutton.org/
 * 
 * Copyright (c) 2012 BigBlueButton Inc. and by respective authors (see below).
 *
 * This program is free software; you can redistribute it and/or modify it under the
 * terms of the GNU Lesser General Public License as published by the Free Software
 * Foundation; either version 3.0 of the License, or (at your option) any later
 * version.
 * 
 * BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
 * PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License along
 * with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.
 *
 */
package org.bigbluebutton.modules.users.business
{
	import com.asfusion.mate.events.Dispatcher;
	
	import flash.events.AsyncErrorEvent;
	import flash.events.NetStatusEvent;
	import flash.net.NetConnection;
	import flash.net.Responder;
	import flash.net.SharedObject;
	
	import org.bigbluebutton.common.LogUtil;
	import org.bigbluebutton.core.EventConstants;
	import org.bigbluebutton.core.UsersUtil;
	import org.bigbluebutton.core.events.CoreEvent;
	import org.bigbluebutton.core.events.LockControlEvent;
	import org.bigbluebutton.core.events.VoiceConfEvent;
	import org.bigbluebutton.core.managers.UserManager;
	import org.bigbluebutton.core.vo.LockSettingsVO;
	import org.bigbluebutton.main.events.BBBEvent;
	import org.bigbluebutton.main.model.users.BBBUser;
	import org.bigbluebutton.main.model.users.Conference;
	import org.bigbluebutton.modules.users.events.UsersEvent;
	
	public class ListenersSOService {
		private static const LOGNAME:String = "[ListenersSOService]";		
		private var _listenersSO : SharedObject;
		private static const SHARED_OBJECT:String = "meetMeUsersSO";		
		private var _conference:Conference;
		private var netConnectionDelegate: NetConnectionDelegate;
		private var _msgListener:Function;
		private var _connectionListener:Function;
		private var _uri:String;
		private var nc_responder : Responder;
		private var _soErrors:Array;
		private var pingCount:int = 0;
		private var _module:UsersModule;
		private var dispatcher:Dispatcher;
		private var moderator:Boolean;
		
		private static var globalDispatcher:Dispatcher = new Dispatcher();
		
		public function ListenersSOService(module:UsersModule) {			
			_conference = UserManager.getInstance().getConference();		
			_module = module;			
			dispatcher = new Dispatcher();
			moderator = _conference.amIModerator();
		}
		
		public function connect(uri:String):void {
			_uri = uri;
			join();
		}
		
		public function disconnect():void {
			leave();
		}
		
		private function connectionListener(connected:Boolean, errors:Array=null):void {
			if (connected) {
				LogUtil.debug(LOGNAME + ":Connected to the VOice application");
				join();
			} else {
				leave();
				LogUtil.debug(LOGNAME + ":Disconnected from the Voice application");
				notifyConnectionStatusListener(false, errors);
			}
		}
		
		private function join():void {
			trace("ListenertsSOService " + _module.uri);
			_listenersSO = SharedObject.getRemote(SHARED_OBJECT, _module.uri, false);
			_listenersSO.addEventListener(NetStatusEvent.NET_STATUS, netStatusHandler);
			_listenersSO.addEventListener(AsyncErrorEvent.ASYNC_ERROR, asyncErrorHandler);
			_listenersSO.client = this;
			_listenersSO.connect(_module.connection);
			LogUtil.debug(LOGNAME + ":Voice is connected to Shared object");
			notifyConnectionStatusListener(true);		
			
			// Query/set lock settings with server 
			getLockSettings();
			// Query the server if there are already listeners in the conference.
			getCurrentUsers();
			getRoomMuteState();
			getRoomLockState();
		}
		
		private function leave():void {
			if (_listenersSO != null) {
				_listenersSO.close();
			}
			notifyConnectionStatusListener(false);
		}
		
		public function addConnectionStatusListener(connectionListener:Function):void {
			_connectionListener = connectionListener;
		}
		   
		public function userJoin(userId:Number, cidName:String, cidNum:String, muted:Boolean, talking:Boolean):void {
			trace("***************** Voice user joining [" + cidName + "]");

			if (cidName) {
				var pattern:RegExp = /(.*)-bbbID-(.*)$/;
				var result:Object = pattern.exec(cidName);
				
				if (result != null) {
					var externUserID:String = result[1] as String;
					var internUserID:String = UsersUtil.externalUserIDToInternalUserID(externUserID);
					
					if (UsersUtil.getMyExternalUserID() == externUserID) {
						_conference.setMyVoiceUserId(userId);
						_conference.muteMyVoice(muted);
						_conference.setMyVoiceJoined(true);
					}
					
					if (UsersUtil.hasUser(internUserID)) {
						var bu:BBBUser = UsersUtil.getUser(internUserID);
						bu.voiceUserid = userId;
						bu.voiceMuted = muted;
						bu.voiceJoined = true;
						
						var bbbEvent:BBBEvent = new BBBEvent(BBBEvent.USER_VOICE_JOINED);
						bbbEvent.payload.userID = bu.userID;            
						globalDispatcher.dispatchEvent(bbbEvent);
						
						if(_conference.getLockSettings().getDisableMic() && !bu.voiceMuted && bu.userLocked && bu.me) {
							var ev:VoiceConfEvent = new VoiceConfEvent(VoiceConfEvent.MUTE_USER);
							ev.userid = userId;
							ev.mute = true;
							dispatcher.dispatchEvent(ev);
						}
					} 
				} else { // caller doesn't exist yet and must be a phone user
					var n:BBBUser = new BBBUser();
					n.name = cidName;
					n.userID = randomString(11);
					n.externUserID = randomString(11);
					n.phoneUser = true;
					n.talking = talking
					n.voiceMuted = muted;
					n.voiceUserid = userId;
					n.voiceJoined = true;
					
					_conference.addUser(n);
				}
			}
		}
		
		private static function randomString(l:uint):String {
			var seed:String = "abcdefghijklmnopqrstuvwxyz1234567890";
			var seedArray:Array = seed.split("");
			var seedLength:uint = seedArray.length;
			var randString:String = "";
			for (var i:uint = 0; i < l; i++){
				randString += seedArray[int(Math.floor(Math.random() * seedLength))];
			}
			return randString;
		}
		
		public function userMute(userID:Number, mute:Boolean):void {
			var l:BBBUser = _conference.getVoiceUser(userID);	
			if (l != null) {
				l.voiceMuted = mute;
				
				if (l.voiceMuted) {
					// When the user is muted, set the talking flag to false so that the UI will not display the
					// user as talking even if muted.
					userTalk(userID, false);
				}
				
				/**
				 * Let's store the voice userid so we can do push to talk.
				 */
				if (l.me) {
					_conference.muteMyVoice(l.voiceMuted);
				}				
				
				LogUtil.debug("[" + l.name + "] is now muted=[" + l.voiceMuted + "]");
				
				var bbbEvent:BBBEvent = new BBBEvent(BBBEvent.USER_VOICE_MUTED);
				bbbEvent.payload.muted = mute;
				bbbEvent.payload.userID = l.userID;
				globalDispatcher.dispatchEvent(bbbEvent);    
			}			     
		}
		
		public function userTalk(userID:Number, talk:Boolean):void {
			trace("User talking event");
			var l:BBBUser = _conference.getVoiceUser(userID);			
			if (l != null) {
				l.talking = talk;
				
				var event:CoreEvent = new CoreEvent(EventConstants.USER_TALKING);
				event.message.userID = l.userID;
				event.message.talking = l.talking;
				globalDispatcher.dispatchEvent(event);  
			}	
		}
		
		public function userLeft(userID:Number):void {
			var l:BBBUser = _conference.getVoiceUser(userID);
			/**
			 * Let's store the voice userid so we can do push to talk.
			 */
			if (l != null) {
				if (_conference.amIThisVoiceUser(userID)) {
					_conference.setMyVoiceJoined(false);
					_conference.setMyVoiceUserId(0);
					_conference.setMyVoiceJoined(false);
				}
				
				l.voiceUserid = 0;
				l.voiceMuted = false;
				l.voiceJoined = false;
				l.talking = false;
        l.userLocked = false;
				
				var bbbEvent:BBBEvent = new BBBEvent(BBBEvent.USER_VOICE_LEFT);
				bbbEvent.payload.userID = l.userID;
				globalDispatcher.dispatchEvent(bbbEvent);
				
				if (l.phoneUser) {
					_conference.removeUser(l.userID);
				}
			}
		}
		
		public function ping(message:String):void {
			if (pingCount < 100) {
				pingCount++;
			} else {
				var date:Date = new Date();
				var t:String = date.toLocaleTimeString();
				LogUtil.debug(LOGNAME + "[" + t + '] - Received ping from server: ' + message);
				pingCount = 0;
			}
		}
		
//		public function lockMuteUser(userid:Number, lock:Boolean):void {
//			var nc:NetConnection = _module.connection;
//			nc.call(
//				"voice.lockMuteUser",// Remote function name
//				new Responder(
//					// participants - On successful result
//					function(result:Object):void { 
//						LogUtil.debug("Successfully lock mute/unmute: " + userid); 	
//					},	
//					// status - On error occurred
//					function(status:Object):void { 
//						LogUtil.error("Error occurred:"); 
//						for (var x:Object in status) { 
//							LogUtil.error(x + " : " + status[x]); 
//						} 
//					}
//				),//new Responder
//				userid,
//				lock
//			); //_netConnection.call		
//		}
		
		public function muteUnmuteUser(userid:Number, mute:Boolean):void {
      var user:BBBUser = UsersUtil.getVoiceUser(userid)
      if (user != null) {
        var nc:NetConnection = _module.connection;
        nc.call(
          "voice.muteUnmuteUser",// Remote function name
          new Responder(
            // participants - On successful result
            function(result:Object):void { 
              LogUtil.debug("Successfully mute/unmute: " + userid); 	
            },	
            // status - On error occurred
            function(status:Object):void { 
              LogUtil.error("Error occurred:"); 
              for (var x:Object in status) { 
                LogUtil.error(x + " : " + status[x]); 
              } 
            }
          ),//new Responder
          user.userID,
          mute
        ); //_netConnection.call	        
      }
	
		}
		
		public function muteAllUsers(mute:Boolean, dontMuteThese:Array = null):void {
			if(dontMuteThese == null) dontMuteThese = [];
			var nc:NetConnection = _module.connection;
			nc.call(
				"voice.muteAllUsers",// Remote function name
				new Responder(
					// participants - On successful result
					function(result:Object):void { 
						LogUtil.debug("Successfully mute/unmute all users: "); 	
					},	
					// status - On error occurred
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				),//new Responder
				mute,
				dontMuteThese
			); //_netConnection.call		
			_listenersSO.send("muteStateCallback", mute);
		}
		
		public function muteStateCallback(mute:Boolean):void {
			var e:UsersEvent = new UsersEvent(UsersEvent.ROOM_MUTE_STATE);
			e.new_state = mute;
			dispatcher.dispatchEvent(e);
		}
		
		public function lockStateCallback(lock:Boolean):void {
			var e:UsersEvent = new UsersEvent(UsersEvent.ROOM_LOCK_STATE);
			e.new_state = lock;
			dispatcher.dispatchEvent(e);
		}
		
		public function ejectUser(userId:Number):void {
      var user:BBBUser = UsersUtil.getVoiceUser(userId)
      if (user != null) {
        var nc:NetConnection = _module.connection;
        nc.call(
          "voice.kickUSer",// Remote function name
          new Responder(
            // participants - On successful result
            function(result:Object):void { 
              LogUtil.debug("Successfully kick user: userId"); 	
            },	
            // status - On error occurred
            function(status:Object):void { 
              LogUtil.error("Error occurred:"); 
              for (var x:Object in status) { 
                LogUtil.error(x + " : " + status[x]); 
              } 
            }
          ),//new Responder
          user.userID
        ); //_netConnection.call        
      }
		
		}
		
		private function getCurrentUsers():void {
			var nc:NetConnection = _module.connection;
			nc.call(
				"voice.getMeetMeUsers",// Remote function name
				new Responder(
					// participants - On successful result
					function(result:Object):void { 
//						LogUtil.debug("Successfully queried participants: " + result.count); 
//						if (result.count > 0) {
//							for(var p:Object in result.participants) 
//							{
//								var u:Object = result.participants[p]
//								userJoin(u.participant, u.name, u.name, u.muted, u.talking);
//							}							
//						}	
					},	
					// status - On error occurred
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
			); //_netConnection.call
		}
		
		public function getRoomMuteState():void{
			var nc:NetConnection = _module.connection;
			nc.call(
				"voice.isRoomMuted",// Remote function name
				new Responder(
					// participants - On successful result
					function(result:Object):void { 
//						var e:UsersEvent = new UsersEvent(UsersEvent.ROOM_MUTE_STATE);
//						e.new_state = result as Boolean;
//						dispatcher.dispatchEvent(e);
					},	
					// status - On error occurred
					function(status:Object):void { 
//						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
			); //_netConnection.call
		}
		
		public function getRoomLockState():void{
      
      return;
      
			var nc:NetConnection = _module.connection;
			nc.call(
				"lock.isRoomLocked",// Remote function name
				new Responder(
					function(result:Object):void { 
//						var e:UsersEvent = new UsersEvent(UsersEvent.ROOM_LOCK_STATE);
//						e.new_state = result as Boolean;
//						dispatcher.dispatchEvent(e);
					},	
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
			); //_netConnection.call
		}
		
		private function notifyConnectionStatusListener(connected:Boolean, errors:Array=null):void {
			if (_connectionListener != null) {
				LogUtil.debug(LOGNAME + 'notifying connectionListener for Voice');
				_connectionListener(connected, errors);
			} else {
				LogUtil.debug(LOGNAME + "_connectionListener is null");
			}
		}
		
		private function netStatusHandler (event:NetStatusEvent):void {
			var statusCode:String = event.info.code;
			
			switch (statusCode) 
			{
				case "NetConnection.Connect.Success":
					LogUtil.debug(LOGNAME + ":Connection Success");			
					break;
				
				case "NetConnection.Connect.Failed":	
					LogUtil.error(LOGNAME + "ChatSO connection failed.");		
					addError("ChatSO connection failed");
					break;
				
				case "NetConnection.Connect.Closed":			
					LogUtil.error(LOGNAME + "Connection to VoiceSO was closed.");						
					addError("Connection to VoiceSO was closed.");									
					notifyConnectionStatusListener(false, _soErrors);
					break;
				
				case "NetConnection.Connect.InvalidApp":	
					LogUtil.error(LOGNAME + "VoiceSO not found in server");			
					addError("VoiceSO not found in server");	
					break;
				
				case "NetConnection.Connect.AppShutDown":
					LogUtil.error(LOGNAME + "VoiceSO is shutting down");	
					addError("VoiceSO is shutting down");
					break;
				
				case "NetConnection.Connect.Rejected":
					LogUtil.error(LOGNAME + "No permissions to connect to the voiceSO");
					addError("No permissions to connect to the voiceSO");
					break;
				
				default:
					LogUtil.debug("ListenersSOService :default - " + event.info.code );
					break;
			}
		}
		
		private function asyncErrorHandler (event:AsyncErrorEvent):void {
			LogUtil.error(LOGNAME + "ListenersSO asynchronous error.");
			addError("ListenersSO asynchronous error.");
		}
		
		private function addError(error:String):void {
			if (_soErrors == null) {
				_soErrors = new Array();
			}
			_soErrors.push(error);
		}
		
		
		/**
		 * Set lock state of all users in the room, except the users listed in second parameter
		 * */
		public function setAllUsersLock(lock:Boolean, except:Array = null):void {
      
      return;
      
			if(except == null) except = [];
			var nc:NetConnection = _module.connection;
			nc.call(
				"lock.setAllUsersLock",// Remote function name
				new Responder(
					function(result:Object):void { 
						LogUtil.debug("Successfully locked all users except " + except.join(","));
					},	
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
				, lock, except
			); //_netConnection.call
			
			_listenersSO.send("lockStateCallback", lock);
		}
		
		/**
		 * Set lock state of all users in the room, except the users listed in second parameter
		 * */
		public function setUserLock(internalUserID:String, lock:Boolean):void {
      
      return;
      
			var nc:NetConnection = _module.connection;
			nc.call(
				"lock.setUserLock",// Remote function name
				new Responder(
					function(result:Object):void { 
						LogUtil.debug("Successfully locked user " + internalUserID);
					},	
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
				, lock, internalUserID
			); //_netConnection.call
		}
		
		
		public function getLockSettings():void{
      
      return;
      
			var nc:NetConnection = _module.connection;
			nc.call(
				"lock.getLockSettings",// Remote function name
				new Responder(
					function(result:Object):void {
//						_conference.setLockSettings(new LockSettingsVO(result.allowModeratorLocking, result.disableCam, result.disableMic, result.disablePrivateChat, result.disablePublicChat));
					},	
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
			); //_netConnection.call
		}
		
		public function saveLockSettings(newLockSettings:Object):void{
      
      return;
      
			var nc:NetConnection = _module.connection;
			nc.call(
				"lock.setLockSettings",// Remote function name
				new Responder(
					function(result:Object):void { 
						
					},	
					function(status:Object):void { 
						LogUtil.error("Error occurred:"); 
						for (var x:Object in status) { 
							LogUtil.error(x + " : " + status[x]); 
						} 
					}
				)//new Responder
				,
				newLockSettings
			); //_netConnection.call
		}
		
		
	}
}