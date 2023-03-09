# OSM-elements-change-tracker

Herramienta para verificar los cambios de elementos en OpenStreetMap.

Este mecanismo es un script en Bash que se puede correr en cualquier máquina
Linux.
Usa overpass para descargar los tipos de elementos de OSM.
Después compara los datos recuperados con una versión previamente guardada en
git.
Si encuentra diferencias envía un reporte a algunas personas por medio de
correo electrónico.

Este repositorio es el resultado de la fusión de chequeo de ciclovías 
([Proyecto de mapeo de ciclovía](https://wiki.openstreetmap.org/wiki/Colombia/Project-Ciclov%C3%ADas]))
y verificación de vías en construcción.
La diferencia de este proyecto es que es independiente del tipo de objeto a
monitorear. Además, incluye los archivos para monitorear los elementos de la
fusión de proyectos: ciclovías y vías en construcción.

## Instalación en Ubuntu

```
sudo apt -y install mutt
```

Y seguir algún tutorial de cómo configurarlo:

* https://www.makeuseof.com/install-configure-mutt-with-gmail-on-linux/
* https://www.dagorret.com.ar/como-utilizar-mutt-con-gmail/

Para esto hay que generar un password desde Gmail.


###  Programación desde cron

```

# Corre el verificador de ciclovias todos los dias.
0 2 * * * cd ~/OSM-elements-change-tracker ; ./verifier.sh ciclovias/diff_relation_ids_ciclovias
0 3 * * * cd ~/OSM-elements-change-tracker ; ./verifier.sh ciclovias/diff_relation_ids_giros

# Correl el verificador de vías en construcción.
0 3 * * * cd ~/OSM-elements-change-tracker ; ./verifier.sh viasEnConstruccion/diff_way_query

# Borra logs viejos de la ciclovia.
0 0 * * * find ~/OSM-elements-change-tracker/ -maxdepth 1 -type f -name "*.log*" -mtime +15 -exec rm {} \;
0 0 * * * find ~/OSM-elements-change-tracker/ -maxdepth 1 -type f -name "*.json" -mtime +15 -exec rm {} \;
0 0 * * * find ~/OSM-elements-change-tracker/ -maxdepth 1 -type f -name "*.txt*" -mtime +15 -exec rm {} \;
```
