CREATE PROCEDURE [dbo].[sp_book_get_available_dates] (

	@spec_ids varchar(max) = null, --Специальности
	@day_time varchar(10) = null, --Утро / День / Ночь (0,1,2), null - весь день
	@doctor_ids varchar(max) = null, --Врачи
	@is_quota_nr bit = 0, --Кроме Квота НР   ---исправить
	@is_without_nr bit = 0, --Кроме врачей НР
	@project_ids varchar(max) = null, -- Филиалы
	@is_hosp_consult bit = 0, --Признак проводит консул.
	@is_priem_children bit = 0, -- Дети
    @is_priem_adults bit = 0, -- Взрослые
	@min_age int = 0,-- Диапазон возраста , с каких лет 	 
    @max_age int = 1000 -- до каких лет
)
as
begin

  set nocount on
  set transaction isolation level read uncommitted

  declare @dt_from date, @dt_to date
  set @dt_from = getdate()
  set @dt_to = eomonth(DateAdd(month,2,@dt_from))
  drop table if exists #t_ids       create table #t_ids(id int not null,index ix_#t_ids clustered(id))
  drop table if exists #t_spec_ids  create table #t_spec_ids (spec_id int not null ,index ix_@t_spec_ids clustered(spec_id))
  drop table if exists #t_hours     create table #t_hours (n_hour int,index ix_@t_hours clustered(n_hour)) 
  drop table if exists #t_quota_nr  create table #t_quota_nr (staff_id int not null, index ix_@t_quota_nr clustered(staff_id))

 -- Крылов С. 02.06.2023 , непонятно , зачем нужна #tmp_query_raspisanie
/*
  drop table if exists #tmp_query_raspisanie
  create table #tmp_query_raspisanie(Raspisanie_id int not null,index ix nonclustered (Raspisanie_id))
  insert #tmp_query_raspisanie(Raspisanie_id)
  select
       r.Raspisanie_id
  from dbo._moss_Raspisanie r
  where r.Raspis_date between @dt_from and @dt_to
*/
  drop table if exists #tmp_source_raspisanie
  create table #tmp_source_raspisanie(Raspis_date date,Staff_Dream_Id int,Specialization_Dream_Id int,Project_Id int,start datetime,pid int)
  insert #tmp_source_raspisanie(Raspis_date,Staff_Dream_Id,Specialization_Dream_Id,Project_Id,start,pid)
  select --distinct
       r.Raspis_date
     , r.Staff_Dream_Id
     , r.Specialization_Dream_Id
     , r.Project_Id
     , r.Start
     , r.pid
  from _moss_Raspisanie as r --join #tmp_query_raspisanie as qr on r.Raspisanie_id=qr.Raspisanie_id
  where r.Raspis_date between @dt_from and @dt_to

  drop table if exists #tmp_rasp
  create table #tmp_rasp (
      id         int  not null identity(1, 1)
    , dt         date not null
    , doc_id     int
    , spec_id    int
    , project_id int
    , isDeleted  bit not null default(0)
    , index ix nonclustered columnstore (dt,doc_id,spec_id,project_id,isDeleted)
  );

  -- Если не переданы никакие фильтры - просто вернем пустоту
  if @spec_ids = null and --Специальности
	   @doctor_ids  = null and --Врачи
	   @is_quota_nr = 0 and --Квота НР
	   @is_without_nr  = 0 and --Кроме НР
	   @project_ids  = null and -- Филиалы
	   @is_hosp_consult  = 0 and --Признак проводит консул.
	   @is_priem_children  = 0 and -- Дети
     @is_priem_adults  = 0  -- Взрослые
  begin
    select [dt] from #tmp_rasp
    Return 0   
  end   
  
 -- часы для выбранного времени суток       
  if @day_time is not null
  begin
    if charindex('0',@day_time) > 0
       insert into #t_hours([n_hour]) 
       select  8
       union select 9
       union select 10
       union select 11
       union select 12
       union select 13
       union select 14
    if charindex('1',@day_time) > 0
       insert into #t_hours([n_hour]) 
       select  15
       union select 16
       union select 17
       union select 18
       union select 19
       union select 20
    if charindex('2',@day_time) > 0
       insert into #t_hours([n_hour]) 
       select  21
       union select 22
       union select 23
       union select 0
       union select 1
       union select 2
       union select 3
       union select 4
       union select 5
       union select 6
       union select 7
  end
           
  -- врачи с признаком Квота НР
  if @is_quota_nr = 1
    insert into #t_quota_nr(staff_id)
    select _moss_sotrudniki_id
    from dbo._moss_sotrudniki
    where isQuotaNR = 1                
                        
  -- расписание за выбраннй интервал  
  -- выбираем весь массив данных (много , но быстро) 
  if @day_time is null -- без фильтра по часам  
  begin
   if @is_quota_nr = 0 -- все кванты (без квоты)
   begin
    insert into #tmp_rasp(dt, doc_id, spec_id,project_id)
    select
        r.Raspis_date,
        r.Staff_Dream_Id,
        r.Specialization_Dream_Id,
        r.Project_Id
    from /*dbo._moss_Raspisanie*/#tmp_source_raspisanie as r
    --where r.Raspis_date between @dt_from and @dt_to
    group by r.Raspis_date,
        r.Staff_Dream_Id,
        r.Specialization_Dream_Id,
        r.Project_Id
   end else -- с квотой (исключая 0-30 мин каждого часа для врачей , у кооторых есть признак Квота НР)
   begin  
    insert into #tmp_rasp(dt, doc_id, spec_id, project_id)
      select
          r.Raspis_date,
          r.Staff_Dream_Id,
          r.Specialization_Dream_Id,
          r.Project_Id
      from  /*dbo._moss_Raspisanie*/#tmp_source_raspisanie as r
      left join #t_quota_nr qnr on qnr.staff_id = r.Staff_Dream_Id
      where /*(r.Raspis_date between @dt_from and @dt_to)
    	  and*/ (
               ((r.pid != 0) and (r.pid is not null))
               or
               ((r.Start >= 30) and (qnr.staff_id is not NULL))
               or
               (qnr.staff_id is null)
              )
      group by r.Raspis_date,
          r.Staff_Dream_Id,
          r.Specialization_Dream_Id,
          r.Project_Id
    end      
  end
  else -- задан интервал часов в сутках
   if @is_quota_nr = 0 -- без квоты
    insert into #tmp_rasp(
        dt,
        doc_id,
        spec_id,
        project_id)
    select
        r.Raspis_date
      , r.Staff_Dream_Id
      , r.Specialization_Dream_Id
      , r.Project_Id
    from /*dbo._moss_Raspisanie*/#tmp_source_raspisanie as r
    where /*r.Raspis_date between @dt_from and @dt_to
      --and DatePart(hour,r.Start) in (select [n_hour] from @t_hours)/*tolbuzov_m 20221123*/
      and */exists(select 1 from #t_hours where [n_hour] = datepart (hour, r.Start))
    group by r.Raspis_date
           , r.Staff_Dream_Id
           , r.Specialization_Dream_Id
           , r.Project_Id;
   else -- с квотой (исключая 0-30 мин каждого часа)
    insert into #tmp_rasp(dt, doc_id, spec_id, project_id)
    select
        r.Raspis_date,
        r.Staff_Dream_Id,
        r.Specialization_Dream_Id,
        r.Project_Id
    from /*dbo._moss_Raspisanie*/#tmp_source_raspisanie as r
    left join #t_quota_nr qnr on qnr.staff_id = r.Staff_Dream_Id
    where /*r.Raspis_date between @dt_from and @dt_to
      --and DatePart(hour,r.Start) in (select [n_hour] from @t_hours)/*tolbuzov_m 20221123*/
      and*/ exists(select 1 from #t_hours where [n_hour] = datepart (hour, r.Start))
    	and (
             ((r.pid != 0) and (r.pid is not null))
             or
             ((r.Start >= 30) and (qnr.staff_id is not NULL))
             or
             (qnr.staff_id is null)
            )

    group by r.Raspis_date,
        r.Staff_Dream_Id,
        r.Specialization_Dream_Id,
        r.Project_Id
        
  -- применяем фильтры, удаляем лишнее
  -- специальности
  if @spec_ids is not NULL
  begin
   truncate table #t_ids

   -- заданные специальности
   insert into #t_spec_ids(spec_id)
   select a.spec_id from(select try_cast([Value] as int) as spec_id from string_split(@spec_ids,','))a 
   where a.spec_id is not null group by a.spec_id

   -- добавляем связанные специальности
   insert into #t_spec_ids(spec_id)
   select distinct
         ls.linked_spec_id
    from #t_spec_ids s
         join dbo.linked_specializations ls on ls.spec_id = s.spec_id
         left join #t_spec_ids ss on ss.spec_id = ls.linked_spec_id
    where ss.spec_id is null
   
   insert into #t_ids(id)
   -- врачи , работающие по заданным специальностям в заданном интервале
   select 
   	  tt.id
   from (
          select  tr.id
          from #tmp_rasp tr   
          --where tr.spec_id in (select spec_id from @t_spec_ids) 
          where exists(select 1 from #t_spec_ids ts where tr.spec_id = ts.spec_id)
          union
          -- врачи , которые в заданном интервале работают по другим специальностям,
          -- но могут принимать и по заданным
          select tr.id
          from #tmp_rasp tr
               join dbo.staff_by_spec_for_raspis sbs on sbs.staff_id = tr.doc_id
                                                    and sbs.spec_id != tr.spec_id
          --where sbs.spec_id in (select spec_id from @t_spec_ids )
          where exists(select 1 from #t_spec_ids ts where sbs.spec_id = ts.spec_id)
   ) tt;    
   
   --delete from #tmp_rasp where id not in (select id from #t_ids)
   update r  set r.isDeleted =1 from #tmp_rasp as r  where  not exists(select 1 from #t_ids ti where r.id=ti.id)
  end

  -- врачи
  if @doctor_ids is not NULL
  begin
   truncate table #t_ids
   insert into #t_ids(id)
   select distinct cast([Value] as int) from string_split(@doctor_ids,',') where isNumeric([Value]) = 1
   
   --delete from #tmp_rasp where doc_id not in (select id from #t_ids)
   update r set r.isDeleted =1 from #tmp_rasp as r  where  not exists(select 1 from #t_ids ti where r.doc_id=ti.id)
  end
  
  -- филиалы
  if @project_ids is not NULL
  begin
   truncate table #t_ids
   insert into #t_ids(id)
   select distinct cast([Value] as int) from string_split(@project_ids,',') where isNumeric([Value]) = 1
   
   --delete from #tmp_rasp where project_id not in (select id from #t_ids)
   update r set r.isDeleted=1 from #tmp_rasp as r  where  not exists(select 1 from #t_ids ti where r.project_id=ti.id)
  end
  
  -- Кроме НР (фильтр убирает врачей из выдачи)
  if @is_without_nr = 1
  BEGIN
   truncate table #t_ids
   insert into #t_ids(id)
   select
   		r.id
   from #tmp_rasp r
   join _moss_sotrudniki doc on doc._moss_sotrudniki_id = r.doc_id
    and doc.isOnlyNR = 1
    
   update r set r.isDeleted=1 from #tmp_rasp as r  where  exists(select 1 from #t_ids ti where r.id=ti.id)
  end

  -- Консультирует в ГЦ
  if @is_hosp_consult = 1
  BEGIN
   truncate table #t_ids
   insert into #t_ids(id)
   select
   		r.id
   from #tmp_rasp r
   join _moss_sotrudniki doc on doc._moss_sotrudniki_id = r.doc_id
    and doc.canHCConsult = 1
    
   --delete from  #tmp_rasp where id not in (select id from #t_ids)  
   update r set r.isDeleted=1 from #tmp_rasp as r  where  not exists(select 1 from #t_ids ti where r.id=ti.id)
  end
  
  -- прием взрослых
  if @is_priem_adults = 1
  BEGIN
  truncate table #t_ids
   insert into #t_ids(id)
   select
   		r.id
   from #tmp_rasp r
   join _moss_sotrudniki doc on doc._moss_sotrudniki_id = r.doc_id
    and doc.PriemAdults = 1
    
   --delete from  #tmp_rasp where id not in (select id from #t_ids)  
   update r set r.isDeleted=1 from #tmp_rasp as r  where  not exists(select 1 from #t_ids ti where r.id=ti.id)
  end

  -- прием детей (и/или интервал возраста)
  if @is_priem_children = 1
  BEGIN
  
   set @min_age =  isNull(@min_age,0)
   set @max_age =  isNull(@max_age,1000)
   delete from #t_ids
   insert into #t_ids(id)
   select
   		r.id
   from #tmp_rasp r
   join _moss_sotr_PatAge pa on pa.staff_id = r.doc_id
    and (
         (isNull(pa.MinAgeYear,0)  between @min_age and @max_age) OR
         (isNull(pa.MaxAgeYear,1000)  between @min_age and @max_age) OR
         (isNull(pa.MinAgeYear,0) < @min_age and isNull(pa.MaxAgeYear,1000) > @max_age)
        ) 
    
   --delete from  #tmp_rasp where id not in (select id from #t_ids)  
   update r set r.isDeleted=1 from #tmp_rasp as r  where  not exists(select 1 from #t_ids ti where r.id=ti.id)
  end
  
  -- выборка уникальных дат
  select 
   [dt]
  from #tmp_rasp
  where isDeleted=0
  group by [dt]
  order by [dt]
  
  drop table #tmp_rasp

  Return 0
  
END
