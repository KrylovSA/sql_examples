CREATE PROCEDURE dbo.sp_lab_pcr(
 @Action varchar(100),
 @Route_IDs varchar(max) = null,
 @xml_data nvarchar(max) = null,
 @Route_ID int = null,
 @FileName varchar(255) = null, 
 @File varbinary(max) = null,
 @Staff_Id int = 2833,
 @UserLogin varchar(100) = NULL
 )
AS
BEGIN
  
/*<?xml version="1.0" encoding="WINDOWS-1251"?>

-<root>
-<Inquiry TimeStamp="" BirthYear="1977" BirthMonth="10" BirthDay="14" Sex="1" MiddleName="Абрахамович" FirstName="Гомер" LastName="Симпсон" OrgID="" RequestID="1001" ID="FE430769-1F29-4E53-8EE5-BFC576F955C6">
-<Sample ID="343317" SamplingDate="2020-04-21T12:00:00" MatID="1" Code="1234567">
<Service Code="271294" Name="Фемофлор 16" ServiceID="Фемофлор 16"/>
<Service Code="271187" Name="Андрофлор®" ServiceID="Андрофлор®"/>
</Sample>
</Inquiry>
-<Inquiry TimeStamp="" BirthYear="1979" BirthMonth="09" BirthDay="22" Sex="2" MiddleName="Гомеровна" FirstName="Луиза" LastName="Симпсон" OrgID="" RequestID="1002" ID="5F91574D-AE13-441E-9F52-E4DB44AAA868">
-<Sample ID="343318" SamplingDate="2020-05-18T13:45:00" MatID="1" Code="1234568">
<Service Code="270666" Name="Определение РНК вируса гриппа А и В (мазки из полости носа и ротоглотки, мокрота)" ServiceID="InflAB"/>
<Service Code="271191" Name="Наследственные случаи рака молочной железы и/или яичников, 2 гена: BRCA1, BRCA2" ServiceID="BRCA"/>
</Sample>
</Inquiry>
</root>*/

set transaction isolation level read uncommitted

declare @XML XML
declare @dtNow datetime = getdate()
declare @RootFolder int
declare  @Comm nvarchar(500), 
         @AID Integer, 
         @TargetPath nvarchar(1000)
DECLARE @ObjectToken INT  
declare @GlobalType_Id int = 122 -- файлы лабораторных направлений
declare @id_analyser int = 18 -- DT Integrator
declare @pid int
declare @SystemDP int = 2833

-- создание заказа для ДТ-интегратора
-- по списку направлений
if @Action = 'Order'
begin
set @XML = 
(select 
 '' [TimeStamp],
 YEAR(pat.Birthday)  [BirthYear],
 MONTH(pat.Birthday) [BirthMonth],
 DAY(pat.Birthday)   [BirthDay],
 case when pat.Sex = 1 then '1' when pat.Sex = 0 then '2' else '' end [Sex],
 pat.MiddleName,
 pat.FirstName,
 pat.LastName,
 '' [OrgID],
 cast(rl.Route_id as varchar(20)) [RequestID],
 cast(NEWID() as varchar(255)) [ID],
 cast((select 
        cast(rl.Route_id as varchar(20)) [ID],
        rl.DateReceive [SamplingDate],
        '1' [MatID],
        cast(rl.PID as varchar(20)) [Code],

		cast(
		    (select
			  lr.Code,
			  lr.ShortName [Name],
			  dt_params.StrCode [ServiceID]
		     from  _moss_analises_group ag 
             join _moss_analises an on an.Analises_group_Id = ag.ID
             join _moss_lab_research lr on lr.ID = an.Recearch_id
             join _moss_ANALISES_PARAM ap on ap.Analises_id = an.id
             join ( select
                     hc.StrCode,
                     lnk.Param_Recearch_ID 
                    from _moss_lab_hrdwr_codes hc
                    left outer join v_moss_lab_auto_recearch_lnk lnk on lnk.Field_ID = hc.id
                    where hc.id_analyser = 18
                  ) dt_params on dt_params.Param_Recearch_ID = ap.Param_Recearch_id
			where ag.RouteToLab_Id = rl.Route_ID
			for XML RAW('Service')) as XML) 

       for XML RAW  ('Sample')	  
      ) as XML) 
from _moss_RouteToLab rl
join _moss_referrals refs on refs.referral_id = rl.referral_id
 and refs.IsDeleted = 0
join _moss_patients pat on pat.pid = rl.pid

		     join  _moss_analises_group ag on ag.RouteToLab_id = rl.Route_Id
             join _moss_analises an on an.Analises_group_Id = ag.ID
             join _moss_lab_research lr on lr.ID = an.Recearch_id
             join _moss_ANALISES_PARAM ap on ap.Analises_id = an.id
             join ( select
                     hc.StrCode,
                     lnk.Param_Recearch_ID 
                    from _moss_lab_hrdwr_codes hc
                    left outer join v_moss_lab_auto_recearch_lnk lnk on lnk.Field_ID = hc.id
                    where hc.id_analyser = 18
                  ) dt_params on dt_params.Param_Recearch_ID = ap.Param_Recearch_id


where rl.Route_ID in (select [Value] from string_split(@Route_IDs,','))
group by 
 rl.Route_id,
 rl.PID,
 rl.DateReceive,
 pat.Birthday,
 pat.Sex,
 pat.MiddleName,
 pat.FirstName,
 pat.LastName
for XML RAW ('Inquiry')
)

--select @XML [xml_order]
select '<?xml version="1.0" encoding="WINDOWS-1251"?>
<root>' + cast(@XML as nvarchar(max)) + '
</root>' [xml_order]

Return 0
end

-- сохранение файла в лаб. направлении
if @Action = 'get_file'
begin

 -- проверим, не сохранен ли уже этот файл
 if exists (select id from pcr_result_files where Route_Id = @Route_ID and File_ID is not null)
  Return 0

 -- ищем корневую папку 
 select top 1 
   @RootFolder = af.[id] 
 from no_moss.dbo._moss_AddFiles as af with(nolock)
 where (af._moss_file_Global_ID = @Route_ID)  
  and (af._moss_files_global_type = @GlobalType_Id) 
  and (af.IsFolder = 1)
  and (af.Name = N'...');

 if @RootFolder is null -- если не нашли, добавляем
 begin
  INSERT INTO no_moss.dbo._moss_AddFiles ([Name], [Description]
           , [_moss_files_global_type], [_moss_file_Global_ID]
           , [_moss_files_date_created], [_moss_files_date_changed]
           , [_moss_files_autor_ID], [_moss_files_changer_ID]
           , [version], [isfolder], [FolderID])
  VALUES ('...', 'Root'
           , @GlobalType_Id, @Route_ID
           , @dtNow,@dtNow
           , @staff_id, @staff_id
           , 0 /* Version */, 1 /* IsFolder */, 0);

  set @RootFolder = IDENT_CURRENT(N'_moss_AddFiles');

  update no_moss.dbo.[_moss_AddFiles]
  set FolderId = @RootFolder
  where (((FolderID is Null)
    or (FolderID = 0)
    or (FolderID = -1))
    and (_moss_files_global_type = @GlobalType_Id)
    and (_moss_file_Global_ID = @Route_ID))
    and isfolder=0
 end; -- if @RootFolder is null

 -- создаем файл 
INSERT INTO no_moss.dbo.[_moss_AddFiles]
           ([Name]
           ,[Description]
           ,[Extension]
           ,[_moss_files_global_type]
           ,[_moss_file_Global_ID]
           ,[_moss_files_date_created]
           ,[_moss_files_date_changed]
           ,[version]
           ,[isfolder]
           ,[FolderID]
           	,_moss_file_Global_Active_Key
           	,Arc 
    	 	,[staff_id_autor]
     		,[staff_id_changer] 
     		,[ToFS]
     		,SizeFile 
  )
     VALUES
           (@FileName
           ,@FileName
           ,'.pdf'
           ,@GlobalType_ID
           ,@Route_ID
           ,@dtNow
           ,@dtNow
           ,1 /*Version*/
           ,0 /*isfolder*/
           ,@RootFolder
           ,'' -- Field_Key
           ,0 --:Arc,
           ,@staff_id
           ,@staff_id
           ,1
           ,Len(@File)   
  )


select @AID = SCOPE_IDENTITY();

set @TargetPath=(select 
               _moss_constant_valueStr 
              from no_moss.dbo._moss_constant (nolock)
              where _moss_constant_name='PathToFS')

set @TargetPath = @TargetPath+'\' + Cast((Cast((@AID/1000) as integer) * 1000) as varchar(12))
set @comm = N'mkdir ' + @TargetPath

EXEC xp_cmdshell @Comm;

-- путь, куда сохраняем файл
set @TargetPath = @TargetPath + '\' + Cast(@AID as varchar(12));

EXEC sp_OACreate 'ADODB.Stream', @ObjectToken OUTPUT  
EXEC sp_OASetProperty @ObjectToken, 'Type', 1   
EXEC sp_OAMethod   @ObjectToken, 'Open'  
EXEC sp_OAMethod @ObjectToken, 'Write', NULL,@File  
EXEC sp_OAMethod @ObjectToken, 'SaveToFile', NULL,@TargetPath, 2   
EXEC sp_OAMethod @ObjectToken, 'Close'  
EXEC sp_OADestroy @ObjectToken

insert into pcr_result_files(
      Route_ID,
      [FileName],
      dtCreate,
      xml_data,
      [File_ID]
      )
values (
      @Route_ID,
      @FileName,
      @dtNow,
      @xml_data,
      @AID
     )      

-- найдем юзера по логину
select top 1
 @Staff_ID = st._moss_sotrudniki_id
from _moss_sotrudniki st
where upper(st._moss_sotrudniki_login) = upper(@UserLogin)


set @Staff_ID = isNull(@Staff_Id,@SystemDP)

-- добавляем комментарий в направление     
update _moss_ANALISES_GROUP set 
 Commentary = 'см. приложенный файл'     ,
 staff_id_modif = @Staff_ID,
 date_modif = @dtNow
where (RouteToLab_ID) = @Route_id 
       and ( (Commentary is null) or (LTRIM(Rtrim(Commentary)) = ''))

-- в поле результата тоже вставляем фразу
update top(1) anlp set
 anlp.[Result] = 'См. прикрепленный файл',
 anlp.date_modif = @dtNow,
 anlp.staff_id_modif = @Staff_ID
from _moss_RouteToLab rl
join _moss_ANALISES_GROUP ag on ag.RouteToLab_id = rl.Route_id
join _moss_analises anl on anl.Analises_group_Id = ag.ID
join _moss_ANALISES_PARAM anlp on anlp.Analises_id = anl.ID
join _moss_LAB_PARAM_RECEARCH lpr on lpr.id = anlp.Param_Recearch_id
join v_moss_lab_auto_recearch_lnk lnk on lnk.Param_Recearch_ID = anlp.Param_Recearch_id
join _moss_lab_hrdwr_codes hc on lnk.Field_ID = hc.id
 and hc.Id_analyser = 18
where rl.Route_id = @Route_ID
 and anlp.[Result] is null

update _moss_RouteToLab set
 [status] = 'анализ выполнен',
 [StaffExplore_id]  = @Staff_ID,
 [DateExplore] = @dtNow,
 id_modif = @Staff_ID,
 date_modif = @dtNow
where Route_ID = @Route_ID
      and [status] != 'анализ выполнен'

return 0

end

-- Получить ИД направления из XML файла
-- Возврат: 0 - уже есть, 1 - новое
if @Action = 'get_route_id'
begin

  set @XML = cast(@xml_data as XML)

  -- PID пациента (для поиска PDF файла)
  SELECT 
    @PID = x.value('@Code', 'varchar(100)') 
  FROM @XML.nodes('/root/Inquiry/Sample') t(x)
  
  -- ИД направления
  SELECT 
    @Route_ID = x.value('@RequestID', 'varchar(100)') 
  FROM @XML.nodes('/root/Inquiry') t(x)

  select @Route_ID [Route_ID], @PID [PID]
  
  if @Route_ID is not null
   if not exists (select 1 from _moss_RouteToLab where Route_id = @Route_ID)
    Return -1 -- направление не найдено
  
  if exists (select 1 from pcr_result_files where Route_id = @Route_ID)
   Return 0  
  else
   Return 1 
end

if @Action = 'get_route_ids'
begin

  set @XML = cast(@xml_data as XML)

  -- ИД направления
  select
   r.Route_ID,
   p.ID fd_pcr_id,
   rl.Route_ID rl_id
  from
  (SELECT 
    x.value('@Code', 'varchar(100)') [Route_ID]
  FROM @XML.nodes('/root/Inquiry/Sample') t(x)) r
  left join _moss_RouteToLab rl on rl.Route_ID = r.Route_ID
  left join pcr_result_files p on p.Route_id = r.Route_ID

  Return 0
end


if @Action = 'get_params'
begin

  set @XML = cast(@xml_data as XML)

  -- ИД направления
/*  SELECT 
    @Route_ID = x.value('@Code', 'varchar(100)') 
  FROM @XML.nodes('/root/Inquiry/Sample') t(x)*/
  
  SELECT 
    @Route_ID = x.value('@RequestID', 'varchar(100)') 
  FROM @XML.nodes('/root/Inquiry') t(x)
  
  if @Route_ID is null
   Return 0

  -- Если уже сохранено - выходим
  if exists (select 1 from _moss_lab_Arch_data
             where id_analyser = @id_analyser
             and SpecimenID = @Route_id)
    Return 0         

  -- пациент
  select 
   @PID = PID
  from _moss_RouteToLab
  where Route_ID =  @Route_ID

 -- сохраняем
 insert into _moss_lab_Arch_data(
  SpecimenID,
  SpecimenName,
  SpecDateTime,
  AssayID,
  AssayName,
  [Result],
  id_analyser,
--  sAssayID,
  Units,
  PID
  )
 
  SELECT 
    @Route_ID,
    p.FIO,
    x.value('@DoneTime','datetime') ,
    null,
--    x.value('../@ServiceID','varchar(1000)') as [ServiceID],
    x.value('@TestID', 'varchar(1000)') ,
    x.value('@Value','varchar(1000)') ,
    @id_analyser,
--    x.value('@TestID', 'varchar(1000)') ,
    null,
    @PID
  FROM @XML.nodes('/root/Inquiry/Sample/Service/Result') t(x)
  join _moss_patients p (nolock) on p.pid = @PID

  Return 0

END

END
