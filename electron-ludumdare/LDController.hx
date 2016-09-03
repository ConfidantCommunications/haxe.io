package ;

import js.Node.*;
import tink.Json.*;
import uhx.util.Backoff;
import unifill.CodePoint;
import uhx.util.Exponential;
import tink.json.Representation;
import haxe.Constraints.Function;

using StringTools;
using sys.io.File;
using haxe.io.Path;
using sys.FileSystem;
using unifill.Unifill;

// This is a _such_ a bad name for this, its not _safe_ at all ;)
@:forward @:forwardStatics abstract SafeValue(String) from String {
	
	@:to public inline function toString():String {
		return this;
	}
	
	@:to public inline function toTinkJson():Representation<Array<Int>> {
		return new Representation( [for (i in 0...this.uLength()) this.uCodePointAt(i).toInt()] );
	}
	
	@:from public static inline function fromTinkJson(r:Representation<Array<Int>>):SafeValue {
		return r.get().map(function(i) return CodePoint.fromInt(i).toString()).join('');
	}
	
}

typedef LDCompetition = {
	var ld:Int;
	var entries:Array<LDEntry>;
	var frameworks:Array<{framework:String}>;
}

typedef LDEntry = {
	var author:LDAuthor;
	var url:SafeValue;
	var name:SafeValue;
	var type:LDType;
	var platforms:Array<LDLink>;
	var frameworks:Array<String>;
}

typedef LDAuthor = {
	var url:SafeValue;
	var name:SafeValue;
}

typedef LDLink = {
	var url:SafeValue;
	var label:SafeValue;
}

@:enum abstract LDType(String) from String to String {
	public var Jam = 'jam';
	public var Compo = 'compo';
}

@:cmd
class LDController {
	
	private static var app:Dynamic;
	private static var electron:Dynamic;
	private static var ipcMain:{on:String->Function->Dynamic, once:String->Function->Dynamic};
	
	public static function main() {
		electron = require('electron');
		app = electron.app;
		ipcMain = electron.ipcMain;
		
		app.on('window-all-closed', function() {
			if (process.platform != 'darwin') {
				//if (Sys.args().indexOf('--wait') == -1) app.quit();
			}
		});
		
		app.on('ready', function() {
			var m = new LDController( Sys.args() );
		} );
	
	}
	
	
	/**
	The minimum amount of milliseconds to wait between scraping requests.
	*/
	@alias
	public var delay:Float = 50;
	
	/**
	The lD competition to search.
	*/
	@alias
	public var number:Int = 36;
	
	/**
	Known entries to include.
	*/
	@alias
	public var entries:Array<String> = [];
	
	/**
	The Haxe frameworks to search for.
	*/
	@alias
	public var frameworks:Array<String> = [];
	
	/**
	Save location.
	*/
	@alias
	public var output:String;
	
	/**
	List of additional scripts to import before the webpage loads.
	*/
	@alias
	@:skip(cmd)
	public var scripts:Array<String> = [];
	
	public var wait:Bool = false;
	public var url:String = 'http://ludumdare.com/compo/ludum-dare-';
	public var search:String = '/?action=preview&q=';
	
	private var cwd = Sys.getCwd();
	// Browser window config
	private var config:Dynamic = { webPreferences:{} };
	
	private var index:Int = 0;
	private var result:LDCompetition;
	
	private var backoff:Backoff;
	private var lastInvoked:Float = 0;
	
	public function new(args:Array<String>) {
		@:cmd _;
		
		init();
		process();
	}
	
	private function init():Void {
		url += '$number/';
		config.webPreferences.preload = '$cwd/ld/scraper.js'.normalize();
		result = {
			ld: number,
			entries: [],
			frameworks: frameworks.map(function(f)return {framework:f}),
		}
		if (output == null || output == '') output = '/ld$number/entries.json';
		
	}
	
	private function process():Void {
		for (framework in frameworks) {
			var browser = untyped __js__('new {0}', electron.BrowserWindow)( config );
			ipcMain.on(framework, recieveEntries.bind(browser, framework, _, _));
			browser.on('closed', function() browser = null );
			browser.webContents.on( 'did-finish-load', onFrameworkLoad.bind( browser, framework ) );
			browser.loadURL( '$url$search' + framework );
			
		}
		
	}
	
	private function onFrameworkLoad(browser:Dynamic, framework:String):Void {
		trace( 'loaded framework scraper', framework );
		browser.webContents.openDevTools();
		browser.webContents.send('payload', framework);
		
	}
	
	private function recieveEntries(browser:Dynamic, framework:String, event:String, data:String):Void {
		trace( 'recieved $framework results' );
		trace( data );
		var json:{data:Array<LDEntry>} = parse( data );
		trace( json );
		
		var entries:Array<LDEntry> = [];
		entries = json.data;
		
		if (entries.length > 0) for (entry in entries) {
			var exists = [for (e in result.entries) if (e.name == entry.name) e];
			if (exists.length == 0) {
				result.entries.push( entry );
				
			} else {
				if (exists[0].frameworks.indexOf(entry.frameworks[0]) == -1) {
					exists[0].frameworks.push( entry.frameworks[0] );
					
				}
				
			}
			
		} else {
			result.frameworks.remove( {framework:framework} );
			
		}
		
		browser.close();
		
		if (frameworks.length > 1) {
			frameworks.remove( framework );
			
		} else {
			frameworks = [];
			processEntries();
			
		}
		
	}
	
	private function processEntries():Void {
		var now = haxe.Timer.stamp();
		trace( 'processing individual entries', lastInvoked, now, now - lastInvoked, (now - lastInvoked) > (delay / 1000), (delay/1000) );
		
		if (lastInvoked == 0) {
			lastInvoked = now;
			backoff = new Backoff( new Expo(), delay, result.entries.length );
			backoff.timeout = 5000;
			
			setTimeout( processEntries, cast delay );
			
		} else/* if ((now - lastInvoked) > (delay / 1000))*/ {
			trace( 'delay exceeded' );
			
			if (index <= (result.entries.length-1)) {
				var entry = result.entries[index];
				trace( 'processing $url${entry.url.toString()}' );
				trace( config );
				var browser = untyped __js__('new {0}', electron.BrowserWindow)( config );
				ipcMain.once('$url${entry.url.toString()}', recieveEntry.bind(browser, entry.url.toString(), _, _));
				browser.on('closed', function() browser = null );
				browser.webContents.on( 'did-finish-load', onEntryLoad.bind( browser, entry ) );
				browser.loadURL( '$url${entry.url.toString()}' );
				
				++index;
				
				lastInvoked = now;
				delay = backoff.next().delay;
				
			} else {
				completeEntries();
				
			}
		
		}
		
	}
	
	private function onEntryLoad(browser:Dynamic, entry:LDEntry):Void {
		trace( 'loaded entry scraper' );
		trace( entry );
		browser.webContents.openDevTools();
		browser.webContents.send('entry', stringify( entry ));
	}
	
	private function recieveEntry(browser:Dynamic, url:String, event:String, data:String):Void {
		trace( url );
		var entry:LDEntry = parse( data );
		var copy = result.entries.copy();
		
		for (i in 0...copy.length) if (copy[i].url == entry.url) {
			result.entries[i] = entry;
			
		}
		
		if (!wait) browser.close();
		trace( 'remaining entries ', index, result.entries.length, index < (result.entries.length) );
		if (index < result.entries.length) {
			setTimeout( processEntries, cast delay );
			
		} else {
			completeEntries();
			
		}
		
	}
	
	private function completeEntries():Void {
		trace( result, output, cwd + output );
		createDirectory( '$cwd/$output'.normalize() );
		'$cwd/$output'.saveContent( haxe.Json.stringify( result ) );
		if (!wait) app.quit();
	}
	
	private static function createDirectory(path:String) {
		if (!path.directory().addTrailingSlash().exists()) {
			
			var parts = path.directory().split('/');
			var missing = [parts.pop()];
			
			while (!Path.join( parts ).normalize().exists()) missing.push( parts.pop() );
			
			missing.reverse();
			
			var directory = Path.join( parts );
			for (part in missing) {
				directory = '$directory/$part/'.normalize().replace(' ', '-');
				if (!directory.exists()) FileSystem.createDirectory( directory );
			}
			
		}
	}
	
}
