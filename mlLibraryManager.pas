{*******************************************************************************
*  Created by Vladimir Georgiev, 2014                                          *
*                                                                              *
*  Description:                                                                *
*  Unit providing several methods to load and use a DLL/BPL library from       *
*  memory instead of a file. The methods are named after the original WinAPIs  *
*  like LoadLibrary, FreeLibrary, GetProcAddress, etc, but with a Mem suffix.  *
*  Same for LoadPackage and UnloadPackage for working with BPLs                *
*  The underlying functionality is provided by the hidden TMlLibraryManager    *
*  class that manages the loading, unloading, reference counting, generation of*
*  handles, etc. It uses the TMlBaseLoader for the loading/unloading of libs.  *
*                                                                              *
*******************************************************************************}

unit mlLibraryManager;

interface

uses
  SysUtils,
  Classes,
  SysConst,
  Windows,
  mlTypes,
  mlBaseLoader,
  mlBPLLoader;

// DLL loading functions. They only forward the calls to the TMlLibraryManager instance
function LoadLibraryMem(aSource: TMemoryStream; aLibFileName: String = ''): TLibHandle;
procedure FreeLibraryMem(hModule: TLibHandle);
function GetProcAddressMem(hModule: TLibHandle; lpProcName: LPCSTR): FARPROC;
function FindResourceMem(hModule: TLibHandle; lpName, lpType: PChar): HRSRC;
function LoadResourceMem(hModule: TLibHandle; hResInfo: HRSRC): HGLOBAL;
function SizeOfResourceMem(hModule: TLibHandle; hResInfo: HRSRC): DWORD;
function GetModuleFileNameMem(hModule: TLibHandle): String;
function GetModuleHandleMem(ModuleName: String): TLibHandle;

/// BPL loading functions
function LoadPackageMem(aSource: TMemoryStream; aLibFileName: String; aValidatePackage: TValidatePackageProc = nil):
    TLibHandle; overload;
procedure UnloadPackageMem(Module: TLibHandle);

//TODO VG 090714: This method is used only to reset the loader during unit testing. Can be removed
{$IFDEF _CONSOLE_TESTRUNNER}
procedure UnloadAllLibrariesMem;
{$ENDIF}

var
  MlOnDependencyLoad: TMlLoadDependentLibraryEvent;

implementation

const
  BASE_HANDLE = $1;  // The minimum value where the allocation of TLibHandle values begins

type
  TMlLibraryManager = class
  private
    fCrit: TRTLCriticalSection;
    fLibs: TList;
    function GetLibs(aIndex: Integer): TMlBaseLoader;
    function GetNewHandle: TLibHandle;
    function LibraryIndexByHandle(aHandle: TLibHandle): Integer;
    function LibraryIndexByName(aName: String): Integer;
    procedure DoDependencyLoad(const aLibName, aDependentLib: String; var aLoadAction: TLoadAction; var aMemStream:
        TMemoryStream; var aFreeStream: Boolean);
    property Libs[aIndex: Integer]: TMlBaseLoader read GetLibs;
  public
    constructor Create;
    destructor Destroy; override;
    function LoadLibraryMl(aSource: TMemoryStream; aLibFileName: String): TLibHandle;
    procedure FreeLibraryMl(aHandle: TLibHandle);
    function GetProcAddressMl(aHandle: TLibHandle; lpProcName: LPCSTR): FARPROC;
    function FindResourceMl(aHandle: TLibHandle; lpName, lpType: PChar): HRSRC;
    function LoadResourceMl(aHandle: TLibHandle; hResInfo: HRSRC): HGLOBAL;
    function SizeOfResourceMl(aHandle: TLibHandle; hResInfo: HRSRC): DWORD;
    function GetModuleFileNameMl(aHandle: TLibHandle): String;
    function GetModuleHandleMl(aModuleName: String): TLibHandle;
    function LoadPackageMl(aSource: TMemoryStream; aLibFileName: String; aValidatePackage: TValidatePackageProc):
        TLibHandle;
    procedure UnloadPackageMl(aHandle: TLibHandle);
  end;

var
  Manager: TMlLibraryManager;

{ DLL Library memory functions }

function LoadLibraryMem(aSource: TMemoryStream; aLibFileName: String = ''): TLibHandle;
begin
  Result := Manager.LoadLibraryMl(aSource, aLibFileName);
end;

procedure FreeLibraryMem(hModule: TLibHandle);
begin
  Manager.FreeLibraryMl(hModule);
end;

function GetProcAddressMem(hModule: TLibHandle; lpProcName: LPCSTR): FARPROC;
begin
  Result := Manager.GetProcAddressMl(hModule, lpProcName);
end;

function FindResourceMem(hModule: TLibHandle; lpName, lpType: PChar): HRSRC;
begin
  Result := Manager.FindResourceMl(hModule, lpName, lpType);
end;

function LoadResourceMem(hModule: TLibHandle; hResInfo: HRSRC): HGLOBAL;
begin
  Result := Manager.LoadResourceMl(hModule, hResInfo);
end;

function SizeOfResourceMem(hModule: TLibHandle; hResInfo: HRSRC): DWORD;
begin
  Result := Manager.SizeOfResourceMl(hModule, hResInfo);
end;

function GetModuleFileNameMem(hModule: TLibHandle): String;
begin
  Result := Manager.GetModuleFileNameMl(hModule);
end;

function GetModuleHandleMem(ModuleName: String): TLibHandle;
begin
  Result := Manager.GetModuleHandleMl(ModuleName);
end;

{ BPL Library memory functions }

function LoadPackageMem(aSource: TMemoryStream; aLibFileName: String; aValidatePackage: TValidatePackageProc = nil):
    TLibHandle;
begin
  Result := Manager.LoadPackageMl(aSource, aLibFileName, aValidatePackage);
end;

procedure UnloadPackageMem(Module: TLibHandle);
begin
  Manager.UnloadPackageMl(Module);
end;

//TODO VG 090714: This method is used only to reset the manager during unit testing. Can be removed
{$IFDEF _CONSOLE_TESTRUNNER}
procedure UnloadAllLibrariesMem;
begin
  Manager.Free;
  Manager := TMlLibraryManager.Create;
end;
{$ENDIF}

{ TMlLibraryManager }

function TMlLibraryManager.GetLibs(aIndex: Integer): TMlBaseLoader;
begin
  if (aIndex < 0) or (aIndex >= fLibs.Count) then
    raise Exception.Create('Library index out of bounds');
  Result := fLibs[aIndex];
end;

/// Generate a unique handle that will be returned as a library identifier
function TMlLibraryManager.GetNewHandle: TLibHandle;
var
  I: Integer;
  Unique: Boolean;
begin
  Result := BASE_HANDLE;
  repeat
    Unique := true;
    for I := 0 to fLibs.Count - 1 do
      if TMlBaseLoader(fLibs[I]).Handle = Result then
      begin
        Unique := false;
        Inc(Result);
        Break;
      end;
  until Unique;
end;

/// Helper method to find the internal index of a loaded library given its handle
/// Used by most other methods that operate on a handle
function TMlLibraryManager.LibraryIndexByHandle(aHandle: TLibHandle): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to fLibs.Count - 1 do
    if Libs[I].Handle = aHandle then
    begin
      Result := I;
      Exit;
    end;
end;

/// Helper method to find the internal index of a loaded library given its handle
/// Used when loading a library to check if loaded already
function TMlLibraryManager.LibraryIndexByName(aName: String): Integer;
var
  I: Integer;
begin
  Result := -1;
  if aName = '' then
    Exit;
  for I := 0 to fLibs.Count - 1 do
    if SameText(Libs[I].Name, ExtractFileName(aName)) then
    begin
      Result := I;
      Exit;
    end;
end;

/// This method is assigned to each TmlBaseLoader and forwards the event to the global MlOnDependencyLoad procedure if one is assigned
procedure TMlLibraryManager.DoDependencyLoad(const aLibName, aDependentLib: String; var aLoadAction: TLoadAction; var
    aMemStream: TMemoryStream; var aFreeStream: Boolean);
begin
  if Assigned(MlOnDependencyLoad) then
    MlOnDependencyLoad(aLibName, aDependentLib, aLoadAction, aMemStream, aFreeStream);
end;

constructor TMlLibraryManager.Create;
begin
  inherited;
  fLibs := TList.Create;
  InitializeCriticalSection(fCrit);
end;

destructor TMlLibraryManager.Destroy;
begin
  while fLibs.Count > 0 do
    FreeLibrary(Libs[0].Handle);
  fLibs.Free;
  DeleteCriticalSection(fCrit);
  inherited;
end;

/// LoadLibraryMem: aName is compared to the loaded libraries and if found the
/// reference count is incremented. If the aName is empty or not found the library is loaded
function TMlLibraryManager.LoadLibraryMl(aSource: TMemoryStream; aLibFileName: String): TLibHandle;
var
  Loader: TMlBaseLoader;
  Index: Integer;
begin
  Result := 0;
  EnterCriticalSection(fCrit);
  try
    Index := LibraryIndexByName(aLibFileName);
    if Index <> -1 then
    begin
      // Increase the RefCount of the already loaded library
      Libs[Index].RefCount := Libs[Index].RefCount + 1;
      Result := Libs[Index].Handle;
    end else
    begin
      // Or load the library if it is a new one
      Loader := TMlBaseLoader.Create;
      try
        fLibs.Add(Loader); // It is added first to reserve the handle given
        Loader.OnDependencyLoad := DoDependencyLoad;
        Loader.Handle := GetNewHandle;
        Loader.RefCount := 1;
        Loader.LoadFromStream(aSource, aLibFileName);
        Result := Loader.Handle;
      except
        fLibs.Remove(Loader);
        Loader.Free;
        raise;
      end;
    end;
  finally
    LeaveCriticalSection(fCrit);
  end;
end;

/// Decrement the RefCount of a library on each call and unload/free it if the count reaches 0
procedure TMlLibraryManager.FreeLibraryMl(aHandle: TLibHandle);
var
  Index: Integer;
  Lib: TMlBaseLoader;
begin
  EnterCriticalSection(fCrit);
  try
    Index := LibraryIndexByHandle(aHandle);
    if Index <> -1 then
    begin
      Lib := Libs[Index];
      Lib.RefCount := Lib.RefCount - 1;
      if Lib.RefCount = 0 then
      begin
        Lib.Free;
        fLibs.Remove(Lib);
      end;
    end
    else
      raise EMlInvalidHandle.Create('Invalid library handle');
  finally
    LeaveCriticalSection(fCrit);
  end;
end;

function TMlLibraryManager.GetProcAddressMl(aHandle: TLibHandle; lpProcName: LPCSTR): FARPROC;
var
  Index: Integer;
begin
  Index := LibraryIndexByHandle(aHandle);
  if Index <> -1 then
    Result := Libs[Index].GetFunctionAddress(lpProcName)
  else
    raise EMlInvalidHandle.Create('Invalid library handle');
end;

function TMlLibraryManager.FindResourceMl(aHandle: TLibHandle; lpName, lpType: PChar): HRSRC;
var
  Index: Integer;
begin
  Index := LibraryIndexByHandle(aHandle);
  if Index <> -1 then
    Result := Libs[Index].FindResourceMl(lpName, lpType)
  else
    raise EMlInvalidHandle.Create('Invalid library handle');
end;

function TMlLibraryManager.LoadResourceMl(aHandle: TLibHandle; hResInfo: HRSRC): HGLOBAL;
var
  Index: Integer;
begin
  Index := LibraryIndexByHandle(aHandle);
  if Index <> -1 then
    Result := Libs[Index].LoadResourceMl(hResInfo)
  else
    raise EMlInvalidHandle.Create('Invalid library handle');
end;

function TMlLibraryManager.SizeOfResourceMl(aHandle: TLibHandle; hResInfo: HRSRC): DWORD;
var
  Index: Integer;
begin
  Index := LibraryIndexByHandle(aHandle);
  if Index <> -1 then
    Result := Libs[Index].SizeOfResourceMl(hResInfo)
  else
    raise EMlInvalidHandle.Create('Invalid library handle');
end;

function TMlLibraryManager.GetModuleFileNameMl(aHandle: TLibHandle): String;
var
  Index: Integer;
begin
  Index := LibraryIndexByHandle(aHandle);
  if Index <> -1 then
    Result := Libs[Index].Name
  else
    raise EMlInvalidHandle.Create('Invalid library handle');
end;

function TMlLibraryManager.GetModuleHandleMl(aModuleName: String): TLibHandle;
var
  Index: Integer;
begin
  Index := LibraryIndexByName(aModuleName);
  if Index <> -1 then
    Result := Libs[Index].Handle
  else
    Result := 0;
end;

/// Function to emulate the LoadPackage from a stream
/// Source is taken from the original Delphi RTL functions LoadPackage, InitializePackage in SysUtils
function TMlLibraryManager.LoadPackageMl(aSource: TMemoryStream; aLibFileName: String; aValidatePackage:
    TValidatePackageProc): TLibHandle;
var
  Loader: TBPLLoader;
  Index: Integer;
begin
  Result := 0;
  EnterCriticalSection(fCrit);
  try
    Index := LibraryIndexByName(aLibFileName);
    if Index <> -1 then
    begin
      // Increase the RefCount of the already loaded library
      Libs[Index].RefCount := Libs[Index].RefCount + 1;
      Result := Libs[Index].Handle;
    end else
    begin
      // Or load the library if it is a new one
      Loader := TBPLLoader.Create;
      try
        fLibs.Add(Loader); // It is added first to reserve the handle given
        Loader.OnDependencyLoad := DoDependencyLoad;
        Loader.Handle := GetNewHandle; // The handle must be assigned before LoadFromStream, because it is used in RegisterModule
        Loader.RefCount := 1;
        Loader.LoadFromStream(aSource, aLibFileName, aValidatePackage);
        Result := Loader.Handle;
      except
        fLibs.Remove(Loader);
        Loader.Free;
        raise;
      end;
    end;
  finally
    LeaveCriticalSection(fCrit);
  end;
end;

procedure TMlLibraryManager.UnloadPackageMl(aHandle: TLibHandle);
var
  Index: Integer;
  Lib: TBPLLoader;
begin
  EnterCriticalSection(fCrit);
  try
    Index := LibraryIndexByHandle(aHandle);
    if Index <> -1 then
    begin
      Lib := Libs[Index] as TBPLLoader;
      Lib.RefCount := Lib.RefCount - 1;
      if Lib.RefCount = 0 then
      begin
        Lib.Free;
        fLibs.Remove(Lib);
      end;
    end
    else
      raise EMlInvalidHandle.Create('Invalid library handle');
  finally
    LeaveCriticalSection(fCrit);
  end;
end;

initialization
  Manager := TMlLibraryManager.Create;

finalization
  Manager.Free;

end.
