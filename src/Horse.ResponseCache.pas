unit Horse.ResponseCache;

{$IF DEFINED(FPC)}
  {$MODE DELPHI}{$H+}
{$ENDIF}

interface

uses
  DateUtils,
  SysUtils,
  SyncObjs,
  Generics.Collections,
  {$IF DEFINED(FPC)}
  HTTPDefs,
  {$ELSE}
  Web.HTTPApp,
  {$ENDIF}
  Horse,
  Horse.Exception.Interrupted;

type
  THorseResponseCacheOptions = class
  private
    FTtlSeconds: Integer;
    FMaxEntries: Integer;
    FVaryAuthorization: Boolean;
    FCacheAll: Boolean;
    FCachePrefixes: TArray<string>;
    FSkipRoutes: TArray<string>;
    function NormalizePath(const APath: string): string;
    function IsSkippedPath(const APath: string): Boolean;
    function IsCacheEnabledForPath(const APath: string): Boolean;
  public
    constructor Create;
    function Clone: THorseResponseCacheOptions;
    function TtlSeconds(const ASeconds: Integer): THorseResponseCacheOptions;
    function MaxEntries(const AMaxEntries: Integer): THorseResponseCacheOptions;
    function VaryAuthorization(const AEnabled: Boolean): THorseResponseCacheOptions;
    function CacheAll(const AEnabled: Boolean = True): THorseResponseCacheOptions;
    function CacheRoutes(const ARoutes: array of string): THorseResponseCacheOptions;
    function SkipRoutes(const ARoutes: array of string): THorseResponseCacheOptions;
  end;

  THorseResponseCache = class
  private
    type
      TEntry = record
      public
        StatusCode: Integer;
        ContentType: string;
        Body: string;
        CreatedAt: TDateTime;
        ExpiresAt: TDateTime;
      end;

      TStore = class
      private
        FLock: TCriticalSection;
        FItems: TDictionary<string, TEntry>;
        function NowUtc: TDateTime;
        procedure CleanupExpired_NoLock;
        procedure EvictOldest_NoLock;
      public
        constructor Create;
        destructor Destroy; override;
        function TryGet(const AKey: string; out AEntry: TEntry): Boolean;
        procedure SetValue(const AKey: string; const AEntry: TEntry;
          const ATtlSeconds: Integer; const AMaxEntries: Integer);
      end;
  end;

function ResponseCache: THorseCallback; overload;
function ResponseCache(const AOptions: THorseResponseCacheOptions): THorseCallback; overload;
function ResponseCache(const ATtlSeconds: Integer; const AMaxEntries: Integer = 5000;
  const AVaryAuthorization: Boolean = True): THorseCallback; overload;
function ResponseCache(const ACacheRoutes: array of string; const ATtlSeconds: Integer = 30;
  const AMaxEntries: Integer = 5000; const AVaryAuthorization: Boolean = True): THorseCallback; overload;

implementation

type
  IResponseCacheContext = interface
    ['{BD308AB6-D269-40A4-B44D-42E05D7B6A8F}']
    function GetOptions: THorseResponseCacheOptions;
    function GetStore: THorseResponseCache.TStore;
    property Options: THorseResponseCacheOptions read GetOptions;
    property Store: THorseResponseCache.TStore read GetStore;
  end;

  TResponseCacheContext = class(TInterfacedObject, IResponseCacheContext)
  private
    FOptions: THorseResponseCacheOptions;
    FStore: THorseResponseCache.TStore;
  public
    constructor Create(AOptions: THorseResponseCacheOptions);
    destructor Destroy; override;
    function GetOptions: THorseResponseCacheOptions;
    function GetStore: THorseResponseCache.TStore;
  end;

var
  GResponseCacheContext: IResponseCacheContext;

function StrStartsWith(const AText, APrefix: string): Boolean;
begin
  if Length(APrefix) > Length(AText) then
    Exit(False);
  Result := Copy(AText, 1, Length(APrefix)) = APrefix;
end;

function StrEndsWith(const AText, ASuffix: string): Boolean;
begin
  if Length(ASuffix) > Length(AText) then
    Exit(False);
  Result := Copy(AText, Length(AText) - Length(ASuffix) + 1, Length(ASuffix)) = ASuffix;
end;

function NormalizeKeyPath(const APath: string): string;
begin
  Result := Trim(LowerCase(APath));

  if Result = '' then
    Exit('/');

  if Result[1] <> '/' then
    Result := '/' + Result;

  while (Length(Result) > 1) and StrEndsWith(Result, '/') do
    Delete(Result, Length(Result), 1);
end;

function SimpleHash32(const S: string): string;
const
  FNV_OFFSET_BASIS = Cardinal($811C9DC5);
  FNV_PRIME = Cardinal(16777619);
var
  I: Integer;
  H: Cardinal;
begin
  H := FNV_OFFSET_BASIS;
  for I := 1 to Length(S) do
  begin
    H := H xor Ord(S[I]);
    H := H * FNV_PRIME;
  end;
  Result := IntToHex(H, 8);
end;

function BuildCacheKey(Req: THorseRequest;
  const AOptions: THorseResponseCacheOptions): string;
var
  LMethod: string;
  LPath: string;
  LQuery: string;
  LAuth: string;
begin
  LMethod := LowerCase(Req.RawWebRequest.Method);
  LPath := NormalizeKeyPath(Req.RawWebRequest.PathInfo);
  LQuery := Req.RawWebRequest.Query;

  if AOptions.FVaryAuthorization then
    LAuth := SimpleHash32(Req.RawWebRequest.Authorization)
  else
    LAuth := '';

  Result := LMethod + ':' + LPath + '?' + LQuery + '|auth=' + LAuth;
end;

procedure ResponseCacheMiddleware(Req: THorseRequest; Res: THorseResponse;
  Next: {$IF DEFINED(FPC)}TNextProc{$ELSE}TProc{$ENDIF});
var
  LKey: string;
  LEntry: THorseResponseCache.TEntry;
begin
  if not Assigned(GResponseCacheContext) then
  begin
    Next;
    Exit;
  end;

  if Req.MethodType <> mtGet then
  begin
    Next;
    Exit;
  end;

  if GResponseCacheContext.Options.IsSkippedPath(Req.RawWebRequest.PathInfo) then
  begin
    Next;
    Exit;
  end;

  if not GResponseCacheContext.Options.IsCacheEnabledForPath(Req.RawWebRequest.PathInfo) then
  begin
    Next;
    Exit;
  end;

  LKey := BuildCacheKey(Req, GResponseCacheContext.Options);

  if GResponseCacheContext.Store.TryGet(LKey, LEntry) then
  begin
    if LEntry.ContentType <> '' then
      Res.ContentType(LEntry.ContentType);

    Res.Status(LEntry.StatusCode);
    Res.Send(LEntry.Body);
    raise EHorseCallbackInterrupted.Create;
  end;

  Next;

  if (Res.RawWebResponse.StatusCode >= 200)
     and (Res.RawWebResponse.StatusCode <= 299)
     and (Res.RawWebResponse.Content <> '') then
  begin
    LEntry := Default(THorseResponseCache.TEntry);
    LEntry.StatusCode := Res.RawWebResponse.StatusCode;
    LEntry.ContentType := Res.RawWebResponse.ContentType;
    LEntry.Body := Res.RawWebResponse.Content;
    LEntry.CreatedAt := 0;
    LEntry.ExpiresAt := 0;

    GResponseCacheContext.Store.SetValue(
      LKey,
      LEntry,
      GResponseCacheContext.Options.FTtlSeconds,
      GResponseCacheContext.Options.FMaxEntries
    );
  end;
end;

{ TResponseCacheContext }

constructor TResponseCacheContext.Create(AOptions: THorseResponseCacheOptions);
begin
  inherited Create;
  FOptions := AOptions;
  FStore := THorseResponseCache.TStore.Create;
end;

destructor TResponseCacheContext.Destroy;
begin
  FStore.Free;
  FOptions.Free;
  inherited;
end;

function TResponseCacheContext.GetOptions: THorseResponseCacheOptions;
begin
  Result := FOptions;
end;

function TResponseCacheContext.GetStore: THorseResponseCache.TStore;
begin
  Result := FStore;
end;

{ THorseResponseCacheOptions }

constructor THorseResponseCacheOptions.Create;
begin
  inherited Create;
  FTtlSeconds := 30;
  FMaxEntries := 5000;
  FVaryAuthorization := True;
  FCacheAll := True;
  FCachePrefixes := [];
  FSkipRoutes := ['/swagger', '/favicon.ico'];
end;

function THorseResponseCacheOptions.Clone: THorseResponseCacheOptions;
begin
  Result := THorseResponseCacheOptions.Create;
  Result.FTtlSeconds := FTtlSeconds;
  Result.FMaxEntries := FMaxEntries;
  Result.FVaryAuthorization := FVaryAuthorization;
  Result.FCacheAll := FCacheAll;
  Result.FCachePrefixes := Copy(FCachePrefixes);
  Result.FSkipRoutes := Copy(FSkipRoutes);
end;

function THorseResponseCacheOptions.TtlSeconds(
  const ASeconds: Integer): THorseResponseCacheOptions;
begin
  if ASeconds > 0 then
    FTtlSeconds := ASeconds;
  Result := Self;
end;

function THorseResponseCacheOptions.MaxEntries(
  const AMaxEntries: Integer): THorseResponseCacheOptions;
begin
  if AMaxEntries > 0 then
    FMaxEntries := AMaxEntries;
  Result := Self;
end;

function THorseResponseCacheOptions.VaryAuthorization(
  const AEnabled: Boolean): THorseResponseCacheOptions;
begin
  FVaryAuthorization := AEnabled;
  Result := Self;
end;

function THorseResponseCacheOptions.CacheAll(
  const AEnabled: Boolean): THorseResponseCacheOptions;
begin
  FCacheAll := AEnabled;
  Result := Self;
end;

function THorseResponseCacheOptions.CacheRoutes(
  const ARoutes: array of string): THorseResponseCacheOptions;
var
  LRoute: string;
  LList: TList<string>;
begin
  LList := TList<string>.Create;
  try
    for LRoute in ARoutes do
      LList.Add(NormalizePath(LRoute));
    FCachePrefixes := LList.ToArray;
  finally
    LList.Free;
  end;

  FCacheAll := Length(FCachePrefixes) = 0;
  Result := Self;
end;

function THorseResponseCacheOptions.SkipRoutes(
  const ARoutes: array of string): THorseResponseCacheOptions;
var
  LRoute: string;
  LList: TList<string>;
begin
  LList := TList<string>.Create;
  try
    for LRoute in ARoutes do
      LList.Add(NormalizePath(LRoute));
    FSkipRoutes := LList.ToArray;
  finally
    LList.Free;
  end;
  Result := Self;
end;

function THorseResponseCacheOptions.NormalizePath(const APath: string): string;
begin
  Result := Trim(LowerCase(APath));

  if Result = '' then
    Exit('/');

  if Result[1] <> '/' then
    Result := '/' + Result;

  while (Length(Result) > 1) and StrEndsWith(Result, '/') do
    Delete(Result, Length(Result), 1);
end;

function THorseResponseCacheOptions.IsSkippedPath(const APath: string): Boolean;
var
  LNeedle: string;
  LPath: string;
begin
  LPath := NormalizePath(APath);

  for LNeedle in FSkipRoutes do
  begin
    if LNeedle = '' then
      Continue;

    if (LPath = LNeedle) or StrStartsWith(LPath, LNeedle + '/') then
      Exit(True);
  end;

  Result := False;
end;

function THorseResponseCacheOptions.IsCacheEnabledForPath(
  const APath: string): Boolean;
var
  LPath: string;
  LPrefix: string;
begin
  if FCacheAll then
    Exit(True);

  LPath := NormalizePath(APath);

  for LPrefix in FCachePrefixes do
  begin
    if LPrefix = '' then
      Continue;

    if (LPath = LPrefix) or StrStartsWith(LPath, LPrefix + '/') then
      Exit(True);
  end;

  Result := False;
end;

{ THorseResponseCache.TStore }

constructor THorseResponseCache.TStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FItems := TDictionary<string, THorseResponseCache.TEntry>.Create;
end;

destructor THorseResponseCache.TStore.Destroy;
begin
  FItems.Free;
  FLock.Free;
  inherited;
end;

function THorseResponseCache.TStore.NowUtc: TDateTime;
begin
  Result := Now;
end;

procedure THorseResponseCache.TStore.CleanupExpired_NoLock;
var
  LKey: string;
  LKeys: TArray<string>;
  LEntry: THorseResponseCache.TEntry;
  LNow: TDateTime;
begin
  LNow := NowUtc;
  LKeys := FItems.Keys.ToArray;

  for LKey in LKeys do
  begin
    if FItems.TryGetValue(LKey, LEntry) then
    begin
      if (LEntry.ExpiresAt > 0) and (LEntry.ExpiresAt <= LNow) then
        FItems.Remove(LKey);
    end;
  end;
end;

procedure THorseResponseCache.TStore.EvictOldest_NoLock;
var
  LPair: TPair<string, TEntry>;
  LOldestKey: string;
  LOldestAt: TDateTime;
  LFound: Boolean;
begin
  LFound := False;
  LOldestKey := '';
  LOldestAt := 0;

  for LPair in FItems do
  begin
    if (not LFound) or (LPair.Value.CreatedAt < LOldestAt) then
    begin
      LFound := True;
      LOldestAt := LPair.Value.CreatedAt;
      LOldestKey := LPair.Key;
    end;
  end;

  if LFound and (LOldestKey <> '') then
    FItems.Remove(LOldestKey);
end;

function THorseResponseCache.TStore.TryGet(
  const AKey: string; out AEntry: THorseResponseCache.TEntry): Boolean;
begin
  Result := False;
  AEntry := Default(THorseResponseCache.TEntry);

  if AKey = '' then
    Exit;

  FLock.Enter;
  try
    CleanupExpired_NoLock;
    Result := FItems.TryGetValue(AKey, AEntry);

    if Result and (AEntry.ExpiresAt > 0) and (AEntry.ExpiresAt <= NowUtc) then
    begin
      FItems.Remove(AKey);
      AEntry := Default(THorseResponseCache.TEntry);
      Result := False;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure THorseResponseCache.TStore.SetValue(const AKey: string;
  const AEntry: THorseResponseCache.TEntry; const ATtlSeconds,
  AMaxEntries: Integer);
var
  LEntry: THorseResponseCache.TEntry;
begin
  if AKey = '' then
    Exit;

  LEntry := AEntry;
  LEntry.CreatedAt := NowUtc;

  if (ATtlSeconds > 0) and (LEntry.ExpiresAt = 0) then
    LEntry.ExpiresAt := LEntry.CreatedAt + (ATtlSeconds / SecsPerDay);

  FLock.Enter;
  try
    CleanupExpired_NoLock;

    if (AMaxEntries > 0)
       and (not FItems.ContainsKey(AKey))
       and (FItems.Count >= AMaxEntries) then
      EvictOldest_NoLock;

    FItems.AddOrSetValue(AKey, LEntry);
  finally
    FLock.Leave;
  end;
end;

function ResponseCache: THorseCallback;
begin
  Result := ResponseCache(nil);
end;

function ResponseCache(
  const AOptions: THorseResponseCacheOptions): THorseCallback;
var
  LOwnedOptions: THorseResponseCacheOptions;
begin
  if Assigned(AOptions) then
    LOwnedOptions := AOptions.Clone
  else
    LOwnedOptions := THorseResponseCacheOptions.Create;

  GResponseCacheContext := TResponseCacheContext.Create(LOwnedOptions);
  Result := ResponseCacheMiddleware;
end;

function ResponseCache(const ATtlSeconds: Integer; const AMaxEntries: Integer;
  const AVaryAuthorization: Boolean): THorseCallback;
var
  LOptions: THorseResponseCacheOptions;
begin
  LOptions := THorseResponseCacheOptions.Create;
  try
    LOptions
      .TtlSeconds(ATtlSeconds)
      .MaxEntries(AMaxEntries)
      .VaryAuthorization(AVaryAuthorization);

    Result := ResponseCache(LOptions);
  finally
    LOptions.Free;
  end;
end;

function ResponseCache(const ACacheRoutes: array of string;
  const ATtlSeconds: Integer; const AMaxEntries: Integer;
  const AVaryAuthorization: Boolean): THorseCallback;
var
  LOptions: THorseResponseCacheOptions;
begin
  LOptions := THorseResponseCacheOptions.Create;
  try
    LOptions
      .TtlSeconds(ATtlSeconds)
      .MaxEntries(AMaxEntries)
      .VaryAuthorization(AVaryAuthorization)
      .CacheRoutes(ACacheRoutes);

    Result := ResponseCache(LOptions);
  finally
    LOptions.Free;
  end;
end;

initialization

finalization
  GResponseCacheContext := nil;

end.
