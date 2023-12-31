CREATE FUNCTION dbo.fn_get_nearest_summa (
 @IDs varchar(2000),
 @Service_Type_ID int,
 @Summa money
)
RETURNS @a table (ID int,kod varchar(100),Price money , CountServ int)
AS
BEGIN

    declare @dtNow datetime = getdate()
	declare @path varchar(100)


 declare @ConsServ table (ID int, kod varchar(20), Amount money)
 
 if @Service_Type_ID = 1
   insert into @ConsServ(ID , kod, Amount )
   select 
    ID,
    kod,
    no_moss.dbo.GetPriceByCodeDream(Kod,1,@dtNow)
   from no_moss.dbo._moss_pol_uslugi 
   where ID  in (select [I] from dbo.fnExplode(@IDs,',','INT'))
  else
   insert into @ConsServ(ID , kod, Amount )
   select 
    ID,
    Code,
    no_moss.dbo.GetPriceByCodeDream(Code,0,@dtNow)
   from no_moss.dbo._moss_LAB_RESEARCH
   where ID  in (select [I] from dbo.fnExplode(@IDs,',','INT'))


	declare @hash table (
	    id int identity(1,1),
		a int, --Точка начальная
		b int, --Точка конечная
		deep int, --Количество промежуточных пунктов
		summ decimal(9,2), --Суммарная длинна пути
		offset decimal(9,2), --Длинна последнего отрезка пути
		path varchar(500) primary key --Строковое выражение пути, ввиде длинны ребер графа через знак плюса, в расчетах не участвуюет
	)

	insert into @hash
	select 
     t1.id,
     t2.id,
     2,
     t1.amount + t2.amount,
     t2.amount, 
     convert(varchar,t1.id)+'.'+convert(varchar,t2.id)
	from @ConsServ t1, @ConsServ t2
	where 
     t1.id <= t2.id 
     and t1.amount + t2.amount <= @summa
     
     
    if @@ROWCOUNT = 0 
    begin
     -- если попали сюда, то можно обойтись одной услугой, кратность 1
     insert into @a
		  select top 1 
		   c.[ID] ,
		   c.kod,
		   c.Amount,
		   1 CountServ
		  from @ConsServ c 
          where c.Amount >= @summa
          order by Abs(c.Amount - @summa)
          
     Return  
    
    end
      

	declare @deep int, @max_deep int

	select 
     @deep = 1, 
     @max_deep = (select count(*) from @ConsServ)

	while @deep <= @max_deep
	begin
	 set @deep += 1
	 
     insert into @hash
	 select 
      h1.a a,
      h2.b b,
      h1.deep + 1 deep,
      h1.summ + h2.offset summ,
      h2.offset offset, 
      h1.path + '.' + convert(varchar,h2.b) path
	 from @hash h1 
     inner join @hash h2 on h1.a < h2.b 
      and h1.b = h2.a 
      and h1.deep = @deep 
      and h2.deep = 2 
      and h1.summ /*+h2.offset*/ <= @summa -- если раскомментить, то в итоге будут варианты только <= @summa

	 if @@ROWCOUNT <= 0
		break
	end -- while @deep <= @max_deep

	--select * from #hash /*where summ = @summ */order by a,b,path

    -- набор услуг, наиболее близкий к заданной сумме
    -- не меньше заданной суммы
    -- и с наименьшим кол-вом услуг 
	select top 1
	  @path = [path]
	from @hash h
    where h.summ >= @summa
    order by Abs(@summa - h.summ),deep 


   insert into @a
		  select 
		   p.[i] ,
		   c.kod,
		   c.Amount,
		   count(p.i) CountServ
		  from dbo.fnExplode(@path,'.','INT') p
		  join @ConsServ c on c.id = p.i
		  group by 
           p.[i] ,
		   c.kod,
		   c.Amount
   Return            
		   

END
