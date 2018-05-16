/***************************************************/
/* Emissions de GES par produit - Mise en forme    */
/*-------------------------------------------------*/
/* Import des donn�es issues des bases Eurostat    */
/* GES 2010, 2011, 2012, 2013, 2014 UE + FR        */
/***************************************************/

%LET rep=\\10.111.201.22\ps_cgdd-bddt\Division_Etudes_Statistiques\USSR; /* R�pertoire de travail */

LIBNAME fichdep "&rep.\Fichdep"; /* Dossier des tables en entr�e */
LIBNAME fichfin "&rep.\Fichfin"; /* Dossier des tables de sortie */

FILENAME ges_r2 "&rep.\Fichdep\env_ac_ainah_r2.tsv"; /* Fichier Eurostat � exploiter */

/*---------------------*/
/* 0. Quelles ann�es ? */
/*---------------------*/

%LET nban_ges2=5; /* 5 ann�es � traiter */
%LET an1_ges2=2010;
%LET an2_ges2=2011;
%LET an3_ges2=2012;
%LET an4_ges2=2013;
%LET an5_ges2=2014;

/*---------------------*/
/* I. Import des bases */
/*---------------------*/

* Les bases de donn�es doivent �tre import�es en 2 fois pour contr�ler les formats des variables tout en �tant surs du nombre d'ann�es disponibles ;

%Macro import_eurostat (base=);

	OPTION OBS=0;
	Proc import DATAFILE=&base. OUT=schema DBMS=dlm REPLACE; DELIMITER='09'x; Run; * Les noms de variables sont import�es dans une table vide ;
	OPTION OBS=max;

	Proc contents DATA=schema OUT=var (KEEP=NAME VARNUM) NOPRINT; Run; * Le contenu de la table vide est identifi� ;
	Proc sort DATA=var; BY VARNUM; Run;

	Data _NULL_; * De nouveaux noms de variables sont cr��s : CHAMP pour la premi�re et Aaaaa pour les autres avec aaaa=ann�e ;
	SET var;
	IF substr(NAME,1,1)="_" THEN DO; var=compress("A"!!substr(NAME,2)); END;
	ELSE var="champ";
	CALL SYMPUT("nbvar",_N_);
	CALL SYMPUT(compress("var"!!_N_),strip(var));
	Run;

	OPTION ERRORS=min;

	Data &base.; /* Mise en place des nouveaux noms */
	INFILE &base. delimiter='09'x MISSOVER DSD lrecl=100000 firstobs=2;
	INFORMAT &var1. $50. %DO i=2 %TO &nbvar.; _&&var&i.._ $100. %END;;
	FORMAT &var1. $50. %DO i=2 %TO &nbvar.; _&&var&i.._ $100. %END;;
	INPUT &var1. %DO i=2 %TO &nbvar.; _&&var&i.._ %END;;
	Run;

	OPTION ERRORS=20;

	Data &base. (DROP=%DO i=2 %TO &nbvar.; _&&var&i.._ %END;); /* Les donn�es sont converties en num�rique */
	SET &base.;
	FORMAT %DO i=2 %TO &nbvar.; &&var&i.. best12. %END;;
	%DO i=2 %TO &nbvar.;
		&&var&i..=translate(_&&var&i.._,"             ","benscfpudirz:"); /* Les caract�res sp�ciaux et lettres pr�sents au milieu des donn�es num�riques sont supprim�s (ex : b=rupture de s�rie, c=confidentiel, d=d�finition diff�rente, voir m�tadonn�es, e=estim�, f=pr�vision, i=voir m�tadonn�es (bient�t supprim�), n=non significatif, p=provisoire, r=r�vis�, s=estimation Eurostat (bient�t supprim�), u =peu fiable, z=non applicable, :=valeur manquante) */
	%END;
	Run;

	* De nombreuses erreurs apparaissent dans le journal du fait de valeurs manquantes repr�sent�es par le caract�re ":" --> ne pas en tenir compte ;

	Proc datasets NOLIST; DELETE schema var; Quit;

%Mend;

%import_eurostat (base=ges_r2); /* GES - NACE rev2 */

/*-------------------------------*/
/* II. Mise en forme des donn�es */
/*-------------------------------*/

/* GES - NACE rev2 */

%Macro ges_r2_modif;

	/* Quelques filtres sont op�r�s :
		- Unit� = millers de tonnes (THS_T)
		- Pays = EUxx, FR
		- Les ann�es d'int�r�t sont conserv�es */

	/* La variable champ est �clat�e en : GES, code produit (NACE), unit�, zone g�o */
	/* Les �missions des m�nages sont conserv�es en nomenclature NACE */
	/* Les �missions des m�nages sont d�taill�es en nomenclature CPA (utilisation de la table de passage) */

	Proc sql NOPRINT; 
	CREATE TABLE ges_r2_modif AS
	SELECT T1.*, scan(T1.champ,4,",") AS pays, scan(T1.champ,3,",") AS unite, scan(T1.champ,1,",") AS ges,
	CASE WHEN substr(T2.code_nace,1,3)="HH_" THEN T2.num_nace ELSE . END AS num_nace,
	CASE WHEN substr(T2.code_nace,1,3)="HH_" THEN T2.code_nace ELSE "" END AS code_nace,
	CASE WHEN substr(T2.code_nace,1,3)="HH_" THEN T2.libelle_nace ELSE "" END AS libelle_nace,
	T4.num_cpa, T4.code_cpa, T4.libelle_cpa
	FROM ges_r2 (KEEP=champ %DO an=1 %TO &nban_ges2.; A&&an&an._ges2. %END;) AS T1
	LEFT JOIN fichdep.nomenclature_nace_rev2 AS T2 ON scan(T1.champ,2,",")=T2.code_nace
	LEFT JOIN fichdep.corresp_cpa_nace_rev2 AS T3 ON scan(T1.champ,2,",")=T3.code_nace
	LEFT JOIN fichdep.nomenclature_cpa_rev2 AS T4 ON T3.code_cpa=T4.code_cpa
	WHERE scan(T1.champ,3,",")="THS_T" AND substr(scan(T1.champ,4,","),1,2) IN ("FR","EU") and (T4.num_cpa ne . or T2.num_nace ne .)
	ORDER BY pays, ges, T4.num_cpa, T2.num_nace;
	Quit;

%Mend;

%ges_r2_modif;

%Macro decompose_ges_r2 (pays=,codpays=,ges=,prg=);

	%DO an=1 %TO &nban_ges2.; /* Boucle sur toutes les ann�es */

		/* Eclatement de chaque table annuelle en 2 parties : m�nages en NACE rev2, entreprises (production) en CPA rev2 */

		Data fichfin.&ges._&codpays._&&an&an._ges2._production (KEEP=num_cpa code_cpa libelle_cpa &ges._&codpays._&&an&an._ges2.)
		fichfin.&ges._&codpays._&&an&an._ges2._menages (KEEP=num_nace code_nace libelle_nace &ges._&codpays._&&an&an._ges2.);
		SET ges_r2_modif (WHERE=(pays="&pays." and ges="&ges.") RENAME=(A&&an&an._ges2.=&ges._&codpays._&&an&an._ges2.));
		&ges._&codpays._&&an&an._ges2.=&ges._&codpays._&&an&an._ges2.*&prg.; /* Application des coefficients PRG : pouvoir de r�chauffement global (�quivalent carbone) */
		IF num_cpa ne . THEN OUTPUT fichfin.&ges._&codpays._&&an&an._ges2._production;
		IF num_nace ne . THEN OUTPUT fichfin.&ges._&codpays._&&an&an._ges2._menages;
		Run;

		Proc sql NOPRINT; /* Production : Agr�gation (si besoin) et mise en forme */
		CREATE TABLE fichfin.&ges._&codpays._&&an&an._ges2._production AS
		SELECT num_cpa, code_cpa, libelle_cpa, CASE WHEN sum(&ges._&codpays._&&an&an._ges2.) ne . THEN sum(&ges._&codpays._&&an&an._ges2.) ELSE 0 END AS &ges._&codpays._&&an&an._ges2.
		FROM fichfin.&ges._&codpays._&&an&an._ges2._production
		GROUP BY num_cpa;
		Quit;

		Proc sql NOPRINT; /* M�nages : Agr�gation (si besoin) et mise en forme */
		CREATE TABLE fichfin.&ges._&codpays._&&an&an._ges2._menages AS
		SELECT num_nace, code_nace, libelle_nace, CASE WHEN sum(&ges._&codpays._&&an&an._ges2.) ne . THEN sum(&ges._&codpays._&&an&an._ges2.) ELSE 0 END AS &ges._&codpays._&&an&an._ges2.
		FROM fichfin.&ges._&codpays._&&an&an._ges2._menages
		GROUP BY num_nace;
		Quit;

	%END;

%Mend;

%decompose_ges_r2 (pays=FR,codpays=FR,ges=CO2,prg=1);
%decompose_ges_r2 (pays=FR,codpays=FR,ges=CH4,prg=25);
%decompose_ges_r2 (pays=FR,codpays=FR,ges=N2O,prg=298);
%decompose_ges_r2 (pays=EU28,codpays=UE,ges=CO2,prg=1);
%decompose_ges_r2 (pays=EU28,codpays=UE,ges=CH4,prg=25);
%decompose_ges_r2 (pays=EU28,codpays=UE,ges=N2O,prg=298);
